import Foundation

public struct CodeAnywhereConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var server: ServerConfiguration
    public var bark: BarkConfiguration
    public var monitor: MonitorConfiguration
    public var statePath: String

    public init(
        version: Int = 1,
        server: ServerConfiguration = .init(),
        bark: BarkConfiguration = .init(),
        monitor: MonitorConfiguration = .init(),
        statePath: String = "~/.local/state/codeanywhere/completion-state.json"
    ) {
        self.version = version
        self.server = server
        self.bark = bark
        self.monitor = monitor
        self.statePath = statePath
    }

    public static var `default`: CodeAnywhereConfiguration { .init() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        server = try container.decodeIfPresent(ServerConfiguration.self, forKey: .server) ?? .init()
        bark = try container.decodeIfPresent(BarkConfiguration.self, forKey: .bark) ?? .init()
        monitor = try container.decodeIfPresent(MonitorConfiguration.self, forKey: .monitor) ?? .init()
        statePath = try container.decodeIfPresent(String.self, forKey: .statePath)
            ?? "~/.local/state/codeanywhere/completion-state.json"
    }

    public func validated() throws -> CodeAnywhereConfiguration {
        guard version == 1 else { throw ConfigurationError.unsupportedVersion(version) }
        guard (1...65_535).contains(server.port) else { throw ConfigurationError.invalidPort(server.port) }
        guard !server.bind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidBind
        }
        guard !server.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidExecutable
        }
        guard !server.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !server.token.contains("\n"), !server.token.contains("\r") else {
            throw ConfigurationError.invalidToken
        }
        guard (1...3_600).contains(monitor.pollIntervalSeconds) else {
            throw ConfigurationError.invalidPollInterval(monitor.pollIntervalSeconds)
        }
        guard (1...100).contains(monitor.maximumDeliveryAttempts) else {
            throw ConfigurationError.invalidMaximumDeliveryAttempts(monitor.maximumDeliveryAttempts)
        }
        guard !statePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidStatePath
        }
        if bark.enabled {
            guard !bark.serverURL.contains("\n"), !bark.deviceKeyEnv.isEmpty else {
                throw ConfigurationError.invalidBarkConfiguration
            }
        }
        return self
    }

    public static func load(from url: URL) throws -> CodeAnywhereConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CodeAnywhereConfiguration.self, from: data).validated()
    }

    public func resolvedStateURL(fileManager: FileManager = .default) -> URL {
        Self.expandPath(statePath, fileManager: fileManager)
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        expandPath("~/.config/codeanywhere/config.json", fileManager: fileManager)
    }

    private static func expandPath(_ path: String, fileManager: FileManager) -> URL {
        let expanded = path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
            .replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [.anchored])
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var executable: String
    public var bind: String
    public var port: Int
    public var token: String
    public var autoStart: Bool

    public init(
        executable: String = "codex",
        bind: String = "0.0.0.0",
        port: Int = 4_500,
        token: String = "codeanywhere-lan-v1",
        autoStart: Bool = true
    ) {
        self.executable = executable
        self.bind = bind
        self.port = port
        self.token = token
        self.autoStart = autoStart
    }
}

public struct BarkConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var serverURL: String
    public var deviceKeyEnv: String
    public var group: String

    public init(
        enabled: Bool = false,
        serverURL: String = "http://127.0.0.1:8080",
        deviceKeyEnv: String = "BARK_DEVICE_KEY",
        group: String = "CodeAnywhere"
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.deviceKeyEnv = deviceKeyEnv
        self.group = group
    }
}

public struct MonitorConfiguration: Codable, Equatable, Sendable {
    public var pollIntervalSeconds: Int
    public var maximumDeliveryAttempts: Int

    public init(pollIntervalSeconds: Int = 5, maximumDeliveryAttempts: Int = 5) {
        self.pollIntervalSeconds = pollIntervalSeconds
        self.maximumDeliveryAttempts = maximumDeliveryAttempts
    }
}

public enum ConfigurationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidPort(Int)
    case invalidBind
    case invalidExecutable
    case invalidToken
    case invalidPollInterval(Int)
    case invalidMaximumDeliveryAttempts(Int)
    case invalidStatePath
    case invalidBarkConfiguration

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "不支持的配置版本：\(version)"
        case .invalidPort(let port): return "监听端口无效：\(port)"
        case .invalidBind: return "监听地址不能为空"
        case .invalidExecutable: return "Codex 可执行文件不能为空"
        case .invalidToken: return "app-server Token 不能为空或包含换行"
        case .invalidPollInterval(let seconds): return "轮询间隔必须为 1-3600 秒：\(seconds)"
        case .invalidMaximumDeliveryAttempts(let attempts): return "最大投递次数必须为 1-100：\(attempts)"
        case .invalidStatePath: return "状态文件路径不能为空"
        case .invalidBarkConfiguration: return "Bark 配置无效；Device Key 只能通过环境变量提供"
        }
    }
}
