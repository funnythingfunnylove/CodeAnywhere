import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum CodexProcessError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case executableNotFound(String)
    case invalidPort
    case tokenFileFailed
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Codex app-server 已经在运行"
        case .executableNotFound(let value): return "找不到 Codex 可执行文件：\(value)"
        case .invalidPort: return "监听端口必须介于 1 到 65535"
        case .tokenFileFailed: return "无法创建权限为 0600 的认证文件"
        case .launchFailed(let message): return "Codex app-server 启动失败：\(message)"
        }
    }
}

public enum CodexExecutableLocator {
    public static func locate(_ configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if configured.contains("/") {
            return FileManager.default.isExecutableFile(atPath: configured) ? URL(fileURLWithPath: configured) : nil
        }
        let path = environment["PATH", default: ""]
        for component in path.split(separator: ":") {
            let candidate = "\(component)/\(configured)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

public final class CodexProcessSupervisor: @unchecked Sendable {
    public private(set) var process: Process?
    public private(set) var tokenFileURL: URL?
    public private(set) var logs: [String] = []

    private let fileManager: FileManager
    private let maximumLogLines = 300

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public var isRunning: Bool { process?.isRunning == true }
    public var pid: Int32? { process?.processIdentifier }

    @discardableResult
    public func start(configuration: ServerConfiguration) throws -> Int32 {
        guard process == nil else { throw CodexProcessError.alreadyRunning }
        guard (1...65_535).contains(configuration.port) else { throw CodexProcessError.invalidPort }
        guard let executable = CodexExecutableLocator.locate(configuration.executable) else {
            throw CodexProcessError.executableNotFound(configuration.executable)
        }

        let tokenURL = try makeTokenFile(token: configuration.token, ownerPID: ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = [
            "app-server", "--listen", "ws://\(configuration.bind):\(configuration.port)",
            "--ws-auth", "capability-token", "--ws-token-file", tokenURL.path
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        installReader(stdout)
        installReader(stderr)
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? fileManager.removeItem(at: tokenURL)
            throw CodexProcessError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.tokenFileURL = tokenURL
        appendLog("Codex app-server 已启动，监听 ws://\(configuration.bind):\(configuration.port)，PID \(process.processIdentifier)")
        return process.processIdentifier
    }

    public func stop() {
        guard let process else {
            // Keep stop idempotent even if a previous launch failed after the
            // token path was recorded.
            if let tokenFileURL { try? fileManager.removeItem(at: tokenFileURL) }
            tokenFileURL = nil
            return
        }

        if process.isRunning {
            // `Process.terminate()` is SIGTERM on Unix.  Codex normally exits
            // promptly, but a stuck app-server must not keep the CLI alive
            // forever (particularly when systemd sends SIGTERM).
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        cleanup(process)
    }

    private func installReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendLog(String(decoding: data, as: UTF8.self))
        }
    }

    private func appendLog(_ text: String) {
        let redacted = text.replacingOccurrences(of: "codeanywhere-lan-v1", with: "<redacted>")
        logs.append(contentsOf: redacted.split(whereSeparator: \.isNewline).map(String.init))
        if logs.count > maximumLogLines { logs.removeFirst(logs.count - maximumLogLines) }
    }

    private func cleanup(_ process: Process) {
        guard self.process === process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let tokenFileURL { try? fileManager.removeItem(at: tokenFileURL) }
        tokenFileURL = nil
        self.process = nil
    }

    private func makeTokenFile(token: String, ownerPID: Int32) throws -> URL {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/codeanywhere/runtime", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Remove capability tokens owned by dead processes (crashed or
        // SIGKILLed parents) so the runtime directory never accumulates
        // stale credentials.  Tokens owned by live processes are untouched.
        if let existing = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            for name in existing {
                guard name.hasPrefix("capability-"), name.hasSuffix(".token"),
                      let pid = Self.ownerPID(from: name),
                      !Self.isAlive(pid) else { continue }
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        let url = directory.appendingPathComponent("capability-\(ownerPID)-\(UUID().uuidString).token")
        try Data(token.utf8).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func ownerPID(from name: String) -> Int32? {
        let components = name.split(separator: "-")
        guard components.count >= 3, let pid = Int32(components[1]) else { return nil }
        return pid
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
