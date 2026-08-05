import Darwin
import Combine
import Foundation

enum ServerProcessError: LocalizedError {
    case alreadyRunning
    case invalidPort
    case executableNotFound
    case tokenFileCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Codex app-server 已经在运行"
        case .invalidPort: return "端口必须介于 1 到 65535"
        case .executableNotFound: return "找不到 codex 可执行文件，请先安装 Codex CLI"
        case .tokenFileCreationFailed: return "无法创建权限为 0600 的认证文件"
        }
    }
}

enum MacServerAuthentication {
    static let capabilityToken = "codeanywhere-lan-v1"
}

enum ServerProcessState: Equatable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping(pid: Int32)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .running, .starting, .stopping: return true
        case .stopped, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "正在启动"
        case .running(let pid): return "运行中 · PID \(pid)"
        case .stopping: return "正在停止"
        case .failed(let message): return "启动失败：\(message)"
        }
    }
}

struct ProcessLogRedactor {
    private static let patterns = [
        #"(?i)(authorization\s*:\s*bearer\s+)[^\s\"',}]+"#,
        #"(?i)(device_key[\"']?\s*[:=]\s*[\"']?)[^\"'\s,}]+"#,
        #"(?i)(--ws-token-sha256\s+)[^\s]+"#
    ]

    static func redact(_ text: String, additionalSecrets: [String] = []) -> String {
        var result = text.replacingOccurrences(of: MacServerAuthentication.capabilityToken, with: "<redacted>")
        for secret in additionalSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        return result
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        if let home = environment["HOME"] {
            candidates.append("\(home)/.local/bin/codex")
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"])

        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

@MainActor
final class ServerProcessController: ObservableObject {
    @Published private(set) var state: ServerProcessState = .stopped
    @Published private(set) var logLines: [String] = []

    var onExit: ((Int32) -> Void)?

    private var ownedProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var tokenFileURL: URL?
    private let executableLocator: () -> URL?
    private let fileManager: FileManager
    private let maximumLogLines = 300

    init(
        fileManager: FileManager = .default,
        executableLocator: @escaping () -> URL? = { CodexExecutableLocator.locate() }
    ) {
        self.fileManager = fileManager
        self.executableLocator = executableLocator
    }

    func start(port: Int) throws {
        guard ownedProcess == nil else { throw ServerProcessError.alreadyRunning }
        guard (1...65_535).contains(port) else { throw ServerProcessError.invalidPort }
        guard let executableURL = executableLocator() else { throw ServerProcessError.executableNotFound }

        state = .starting
        let tokenURL: URL
        do {
            tokenURL = try createCapabilityTokenFile()
        } catch {
            state = .failed(ServerProcessError.tokenFileCreationFailed.localizedDescription)
            throw ServerProcessError.tokenFileCreationFailed
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--listen", "ws://0.0.0.0:\(port)",
            "--ws-auth", "capability-token",
            "--ws-token-file", tokenURL.path
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                self?.processDidExit(terminatedProcess)
            }
        }
        installReader(on: stdout)
        installReader(on: stderr)

        do {
            try process.run()
            ownedProcess = process
            outputPipe = stdout
            errorPipe = stderr
            tokenFileURL = tokenURL
            state = .running(pid: process.processIdentifier)
            appendLog("Codex app-server 已启动，监听端口 \(port)")
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? fileManager.removeItem(at: tokenURL)
            state = .failed(error.localizedDescription)
            appendLog("启动失败：\(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    func stop(waitUntilExit: Bool = false) -> Bool {
        guard let process = ownedProcess else { return true }
        let pid = process.processIdentifier
        guard process.isRunning else {
            processDidExit(process)
            return true
        }
        state = .stopping(pid: pid)
        appendLog("正在停止由本应用启动的 Codex app-server（PID \(pid)）")
        process.terminate()
        if waitUntilExit {
            if waitForExit(process, timeout: 2) {
                processDidExit(process)
                return true
            }
            appendLog("进程未及时退出，正在强制停止由本应用持有的 PID \(pid)")
            Darwin.kill(pid, SIGKILL)
            if waitForExit(process, timeout: 1) {
                processDidExit(process)
                return true
            }
            appendLog("无法在限定时间内确认 PID \(pid) 已退出，已取消退出应用")
            return false
        }
        return true
    }

    func clearLogs() {
        logLines.removeAll()
    }

    private func installReader(on pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }
    }

    private func appendLog(_ text: String) {
        let redacted = ProcessLogRedactor.redact(text)
        let lines = redacted.split(whereSeparator: \.isNewline).map(String.init)
        logLines.append(contentsOf: lines)
        if logLines.count > maximumLogLines {
            logLines.removeFirst(logLines.count - maximumLogLines)
        }
    }

    private func processDidExit(_ process: Process) {
        guard process === ownedProcess else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        if let tokenFileURL {
            try? fileManager.removeItem(at: tokenFileURL)
        }
        tokenFileURL = nil
        ownedProcess = nil
        state = .stopped
        appendLog("Codex app-server 已退出（状态码 \(process.terminationStatus)）")
        onExit?(process.terminationStatus)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private func createCapabilityTokenFile() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("CodeAnywhere Mac", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("capability-\(UUID().uuidString).token")
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw ServerProcessError.tokenFileCreationFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            try? fileManager.removeItem(at: url)
            throw ServerProcessError.tokenFileCreationFailed
        }

        let bytes = Array(MacServerAuthentication.capabilityToken.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            guard written > 0 else {
                try? fileManager.removeItem(at: url)
                throw ServerProcessError.tokenFileCreationFailed
            }
            offset += written
        }
        return url
    }
}
