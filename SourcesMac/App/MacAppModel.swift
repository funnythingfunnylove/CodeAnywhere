import Combine
import Foundation

enum BarkConfigurationStatus: Equatable {
    case idle
    case working
    case success(String)
    case failure(String)

    var message: String? {
        switch self {
        case .idle: return nil
        case .working: return "正在联系 Bark Server…"
        case .success(let message), .failure(let message): return message
        }
    }
}

enum MacAppVersion {
    static var display: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return formatted(shortVersion: shortVersion, build: build)
    }

    static func formatted(shortVersion: String?, build: String?) -> String {
        let resolvedVersion = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (resolvedVersion?.isEmpty == false ? resolvedVersion : nil,
                resolvedBuild?.isEmpty == false ? resolvedBuild : nil) {
        case let (.some(version), .some(build)): return "版本 \(version)（\(build)）"
        case let (.some(version), .none): return "版本 \(version)"
        case let (.none, .some(build)): return "构建 \(build)"
        case (.none, .none): return "版本未知"
        }
    }
}

@MainActor
final class MacAppModel: ObservableObject {
    @Published var configuredPort: Int {
        didSet { defaults.set(configuredPort, forKey: Keys.port) }
    }
    @Published var startsAutomatically: Bool {
        didSet { defaults.set(startsAutomatically, forKey: Keys.autoStart) }
    }
    @Published var barkServerURL: String {
        didSet {
            defaults.set(barkServerURL, forKey: Keys.barkServerURL)
            monitor.barkServerURL = BarkServerConfiguration.resolvedURL(from: barkServerURL)
        }
    }
    @Published var barkStyle: BarkNotificationStyle {
        didSet {
            if let data = try? JSONEncoder().encode(barkStyle) {
                defaults.set(data, forKey: Keys.barkStyle)
            }
            monitor.notificationStyle = barkStyle
        }
    }
    @Published private(set) var hasStoredDeviceKey = false
    @Published private(set) var barkStatus: BarkConfigurationStatus = .idle

    let server: ServerProcessController
    let monitor: CompletionMonitor
    let codex: CodexInstallationController

    var versionDisplay: String { MacAppVersion.display }
    var localServerEndpoint: String? {
        LocalNetworkAddressResolver.preferredIPv4Address().map {
            "ws://\($0):\(configuredPort)"
        }
    }
    var canStartServer: Bool { !server.state.isRunning && !codex.updateState.isWorking }
    var canUpdateCodex: Bool { !server.state.isRunning && !codex.updateState.isWorking }
    var operatingSystemDisplay: String { ProcessInfo.processInfo.operatingSystemVersionString }
    var architectureDisplay: String {
#if arch(arm64)
        return "Apple Silicon (arm64)"
#elseif arch(x86_64)
        return "Intel (x86_64)"
#else
        return "未知架构"
#endif
    }

    private let defaults: UserDefaults
    private let deviceKeyStore: any DeviceKeyStoring
    private let barkSender: any BarkSending
    private var didHandleInitialLaunch = false
    private var cancellables = Set<AnyCancellable>()

    init(
        defaults: UserDefaults = .standard,
        server: ServerProcessController? = nil,
        monitor: CompletionMonitor? = nil,
        codex: CodexInstallationController? = nil,
        deviceKeyStore: any DeviceKeyStoring = KeychainDeviceKeyStore(),
        barkSender: any BarkSending = BarkClient()
    ) {
        self.defaults = defaults
        let resolvedServer = server ?? ServerProcessController()
        let resolvedMonitor = monitor ?? CompletionMonitor()
        self.server = resolvedServer
        self.monitor = resolvedMonitor
        self.codex = codex ?? CodexInstallationController()
        self.deviceKeyStore = deviceKeyStore
        self.barkSender = barkSender
        let savedPort = defaults.integer(forKey: Keys.port)
        configuredPort = (1...65_535).contains(savedPort) ? savedPort : 4_500
        startsAutomatically = defaults.object(forKey: Keys.autoStart) as? Bool ?? false
        let savedBarkServerURL = defaults.string(forKey: Keys.barkServerURL)
        barkServerURL = BarkServerConfiguration.resolvedURL(from: savedBarkServerURL)
        if let styleData = defaults.data(forKey: Keys.barkStyle),
           let savedStyle = try? JSONDecoder().decode(BarkNotificationStyle.self, from: styleData) {
            barkStyle = savedStyle
        } else {
            barkStyle = .codexDefault
        }
        if savedBarkServerURL != barkServerURL {
            defaults.set(barkServerURL, forKey: Keys.barkServerURL)
        }
        resolvedMonitor.barkServerURL = barkServerURL
        resolvedMonitor.notificationStyle = barkStyle
        hasStoredDeviceKey = (try? deviceKeyStore.read())?.isEmpty == false
        resolvedServer.onExit = { [weak resolvedMonitor] _ in
            resolvedMonitor?.stop()
        }
        resolvedServer.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        resolvedMonitor.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.codex.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func handleInitialLaunch() {
        guard !didHandleInitialLaunch else { return }
        didHandleInitialLaunch = true
        Task { await codex.refresh() }
        if startsAutomatically { startServer() }
    }

    func startServer() {
        guard canStartServer else { return }
        do {
            try server.start(port: configuredPort)
            monitor.barkServerURL = BarkServerConfiguration.resolvedURL(from: barkServerURL)
            monitor.start(port: configuredPort)
        } catch {
            barkStatus = .failure(ProcessLogRedactor.redact(error.localizedDescription))
        }
    }

    func updateCodex() async {
        guard canUpdateCodex else { return }
        await codex.updateCodex()
    }

    func stopServer() {
        monitor.stop()
        server.stop()
    }

    func shutdownForQuit() -> Bool {
        monitor.stop()
        return server.stop(waitUntilExit: true)
    }

    func saveDeviceKey(_ key: String) {
        do {
            try deviceKeyStore.save(key)
            hasStoredDeviceKey = true
            barkStatus = .success("Device Key 已安全保存到 macOS Keychain")
        } catch {
            barkStatus = .failure(error.localizedDescription)
        }
    }

    func deleteDeviceKey() {
        do {
            try deviceKeyStore.delete()
            hasStoredDeviceKey = false
            barkStatus = .success("已从 macOS Keychain 删除 Device Key")
        } catch {
            barkStatus = .failure(error.localizedDescription)
        }
    }

    func sendBarkTest() async {
        barkStatus = .working
        do {
            guard let deviceKey = try deviceKeyStore.read(), !deviceKey.isEmpty else {
                throw DeviceKeyStoreError.emptyKey
            }
            let testID = "codeanywhere-test-\(UUID().uuidString.lowercased())"
            let notification = barkStyle.notification(
                threadTitle: "Bark 测试提醒",
                statusTitle: "CodeAnywhere 测试",
                completedAt: Date(),
                url: "codeanywhere://thread/bark-test",
                id: testID
            )
            try await barkSender.send(
                notification,
                deviceKey: deviceKey,
                serverURL: BarkServerConfiguration.resolvedURL(from: barkServerURL)
            )
            barkStatus = .success("Bark Server 已接受测试请求；请在 iPhone 上确认是否显示")
        } catch {
            barkStatus = .failure(ProcessLogRedactor.redact(error.localizedDescription))
        }
    }

    private enum Keys {
        static let port = "mac.server.port"
        static let autoStart = "mac.server.autoStart"
        static let barkServerURL = "mac.bark.serverURL"
        static let barkStyle = "mac.bark.notificationStyle"
    }
}
