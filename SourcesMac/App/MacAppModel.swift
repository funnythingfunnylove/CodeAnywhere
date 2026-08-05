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
            monitor.barkServerURL = barkServerURL
        }
    }
    @Published private(set) var hasStoredDeviceKey = false
    @Published private(set) var barkStatus: BarkConfigurationStatus = .idle

    let server: ServerProcessController
    let monitor: CompletionMonitor

    private let defaults: UserDefaults
    private let deviceKeyStore: any DeviceKeyStoring
    private let barkSender: any BarkSending
    private var didHandleInitialLaunch = false

    init(
        defaults: UserDefaults = .standard,
        server: ServerProcessController? = nil,
        monitor: CompletionMonitor? = nil,
        deviceKeyStore: any DeviceKeyStoring = KeychainDeviceKeyStore(),
        barkSender: any BarkSending = BarkClient()
    ) {
        self.defaults = defaults
        let resolvedServer = server ?? ServerProcessController()
        let resolvedMonitor = monitor ?? CompletionMonitor()
        self.server = resolvedServer
        self.monitor = resolvedMonitor
        self.deviceKeyStore = deviceKeyStore
        self.barkSender = barkSender
        let savedPort = defaults.integer(forKey: Keys.port)
        configuredPort = (1...65_535).contains(savedPort) ? savedPort : 4_500
        startsAutomatically = defaults.object(forKey: Keys.autoStart) as? Bool ?? false
        barkServerURL = defaults.string(forKey: Keys.barkServerURL) ?? "http://192.168.1.10:8888"
        resolvedMonitor.barkServerURL = barkServerURL
        hasStoredDeviceKey = (try? deviceKeyStore.read())?.isEmpty == false
        resolvedServer.onExit = { [weak resolvedMonitor] _ in
            resolvedMonitor?.stop()
        }
    }

    func handleInitialLaunch() {
        guard !didHandleInitialLaunch else { return }
        didHandleInitialLaunch = true
        if startsAutomatically { startServer() }
    }

    func startServer() {
        do {
            try server.start(port: configuredPort)
            monitor.barkServerURL = barkServerURL
            monitor.start(port: configuredPort)
        } catch {
            barkStatus = .failure(ProcessLogRedactor.redact(error.localizedDescription))
        }
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
            try await barkSender.send(
                BarkNotification(
                    title: "CodeAnywhere 测试",
                    body: "Mac 伴侣已连接到 Bark Server",
                    group: "CodeAnywhere",
                    url: "codeanywhere://thread/bark-test",
                    id: testID
                ),
                deviceKey: deviceKey,
                serverURL: barkServerURL
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
    }
}
