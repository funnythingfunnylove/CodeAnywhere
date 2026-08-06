import Combine
import Foundation

struct CodexCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
}

protocol CodexCommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CodexCommandResult
}

struct ProcessCodexCommandRunner: CodexCommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CodexCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CodexCommandResult(
                exitCode: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
    }
}

enum CodexCLIOutputParser {
    static func version(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(whereSeparator: \Character.isWhitespace)
        guard let candidate = components.last, candidate.contains(where: \.isNumber) else { return nil }
        return String(candidate)
    }
}

enum CodexUpdateState: Equatable {
    case idle
    case checking
    case updating
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "已就绪"
        case .checking: return "正在读取 Codex 信息…"
        case .updating: return "正在执行 codex update…"
        case .succeeded(let message), .failed(let message): return message
        }
    }

    var isWorking: Bool {
        self == .checking || self == .updating
    }
}

@MainActor
final class CodexInstallationController: ObservableObject {
    @Published private(set) var executablePath = "未找到 Codex CLI"
    @Published private(set) var version = "未检测"
    @Published private(set) var updateState: CodexUpdateState = .idle
    @Published private(set) var lastCommandOutput = ""
    @Published private(set) var lastCheckedAt: Date?

    private let executableLocator: @Sendable () -> URL?
    private let runner: any CodexCommandRunning

    init(
        executableLocator: @escaping @Sendable () -> URL? = { CodexExecutableLocator.locate() },
        runner: any CodexCommandRunning = ProcessCodexCommandRunner()
    ) {
        self.executableLocator = executableLocator
        self.runner = runner
    }

    func refresh() async {
        updateState = .checking
        do {
            let executable = try resolvedExecutable()
            record(version: try await readVersion(using: executable))
            updateState = .idle
        } catch {
            lastCheckedAt = Date()
            updateState = .failed(ProcessLogRedactor.redact(error.localizedDescription))
        }
    }

    func updateCodex() async {
        updateState = .updating
        do {
            let executable = try resolvedExecutable()
            let updateResult = try await runner.run(executable: executable, arguments: ["update"])
            lastCommandOutput = ProcessLogRedactor.redact(updateResult.output)
            guard updateResult.exitCode == 0 else {
                throw CodexInstallationError.commandFailed(updateResult.output)
            }
            let resolvedVersion = try await readVersion(using: executable)
            record(version: resolvedVersion)
            updateState = .succeeded("Codex 已更新至 \(resolvedVersion)")
        } catch {
            updateState = .failed(ProcessLogRedactor.redact(error.localizedDescription))
        }
    }

    private func resolvedExecutable() throws -> URL {
        guard let executable = executableLocator() else {
            executablePath = "未找到 Codex CLI"
            version = "未安装"
            throw CodexInstallationError.executableNotFound
        }
        executablePath = executable.path
        return executable
    }

    private func readVersion(using executable: URL) async throws -> String {
        let result = try await runner.run(executable: executable, arguments: ["--version"])
        guard result.exitCode == 0,
              let resolvedVersion = CodexCLIOutputParser.version(from: result.output) else {
            throw CodexInstallationError.commandFailed(result.output)
        }
        return resolvedVersion
    }

    private func record(version: String) {
        self.version = version
        lastCheckedAt = Date()
    }
}

private enum CodexInstallationError: LocalizedError {
    case executableNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 codex 可执行文件"
        case .commandFailed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Codex 命令执行失败" : "Codex 命令执行失败：\(trimmed)"
        }
    }
}
