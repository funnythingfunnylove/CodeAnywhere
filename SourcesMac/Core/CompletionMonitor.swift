import Combine
import Foundation

enum CompletionMonitorStatus: Equatable {
    case stopped
    case connecting
    case monitoring
    case retrying(String)

    var label: String {
        switch self {
        case .stopped: return "监控已停止"
        case .connecting: return "正在连接本机 app-server"
        case .monitoring: return "正在监控对话完成状态"
        case .retrying(let message): return "等待重试：\(message)"
        }
    }
}

@MainActor
final class CompletionMonitor: ObservableObject {
    @Published private(set) var status: CompletionMonitorStatus = .stopped
    @Published private(set) var lastSuccessfulPoll: Date?
    @Published private(set) var pendingCount = 0
    @Published private(set) var deliveredCount = 0

    private let persistence: any CompletionStatePersisting
    private let deviceKeyStore: any DeviceKeyStoring
    private let barkSender: any BarkSending
    private let retryPolicy: DeliveryRetryPolicy
    private let clientFactory: @Sendable (Int) -> any MacCodexClientProtocol
    private var monitorState: CompletionMonitorState
    private var client: (any MacCodexClientProtocol)?
    private var pollTask: Task<Void, Never>?
    private var currentPort: Int?
    private var consecutivePollFailures = 0
    private var isPolling = false

    var barkServerURL: String = ""

    init(
        persistence: any CompletionStatePersisting = FileCompletionStateStore(),
        deviceKeyStore: any DeviceKeyStoring = KeychainDeviceKeyStore(),
        barkSender: any BarkSending = BarkClient(),
        retryPolicy: DeliveryRetryPolicy = .standard,
        now: Date = Date(),
        clientFactory: @escaping @Sendable (Int) -> any MacCodexClientProtocol = {
            MacCodexWebSocketClient(port: $0)
        }
    ) {
        self.persistence = persistence
        self.deviceKeyStore = deviceKeyStore
        self.barkSender = barkSender
        self.retryPolicy = retryPolicy
        self.clientFactory = clientFactory
        monitorState = persistence.load(now: now)
        updateCounts()
    }

    func start(port: Int) {
        stop()
        currentPort = port
        status = .connecting
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        let oldClient = client
        client = nil
        currentPort = nil
        status = .stopped
        Task { await oldClient?.disconnect() }
    }

    func pollNow() {
        guard currentPort != nil else { return }
        Task { [weak self] in
            await self?.performPollIfNeeded()
        }
    }

    func retryFailedDeliveries() {
        let now = Date()
        for id in monitorState.pending.keys {
            monitorState.pending[id]?.attempts = 0
            monitorState.pending[id]?.nextAttemptAt = now
        }
        persistState()
        pollNow()
    }

    private func runLoop() async {
        while !Task.isCancelled, currentPort != nil {
            await performPollIfNeeded()
            let delay = min(60.0, 5.0 * pow(2, Double(max(0, consecutivePollFailures - 1))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func performPollIfNeeded() async {
        guard !isPolling, let port = currentPort else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            let client = try await connectedClient(port: port)
            let snapshots = try await fetchAllThreads(using: client)
            let now = Date()
            CompletionDetector.observe(snapshots: snapshots, state: &monitorState, now: now)
            try persistence.save(monitorState)
            lastSuccessfulPoll = now
            consecutivePollFailures = 0
            status = .monitoring
            updateCounts()
            await deliverDueNotifications(now: now)
        } catch {
            consecutivePollFailures += 1
            status = .retrying(ProcessLogRedactor.redact(error.localizedDescription))
            let oldClient = client
            client = nil
            await oldClient?.disconnect()
        }
    }

    private func connectedClient(port: Int) async throws -> any MacCodexClientProtocol {
        if let client { return client }
        status = .connecting
        let newClient = clientFactory(port)
        try await newClient.connect()
        client = newClient
        return newClient
    }

    private func fetchAllThreads(using client: any MacCodexClientProtocol) async throws -> [MonitoredThreadSnapshot] {
        var snapshotsByID: [String: MonitoredThreadSnapshot] = [:]
        for archived in [false, true] {
            var cursor: String?
            var pageCount = 0
            repeat {
                pageCount += 1
                guard pageCount <= 100 else { throw MacCodexClientError.malformedResponse }
                var params: [String: MacJSONValue] = [
                    "limit": .number(100),
                    "sortKey": .string("updated_at"),
                    "sortDirection": .string("desc"),
                    "modelProviders": .array([]),
                    "archived": .bool(archived)
                ]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try await client.call(method: "thread/list", params: params)
                for value in result["data"]?.arrayValue ?? [] {
                    if let snapshot = MonitoredThreadSnapshot(json: value) {
                        snapshotsByID[snapshot.id] = snapshot
                    }
                }
                let next = result["nextCursor"]?.stringValue
                cursor = next?.isEmpty == false ? next : nil
            } while cursor != nil
        }
        return Array(snapshotsByID.values)
    }

    private func deliverDueNotifications(now: Date) async {
        let due = monitorState.pending.values
            .filter { $0.attempts < retryPolicy.maximumAttempts && $0.nextAttemptAt <= now }
            .sorted { $0.threadUpdatedAt < $1.threadUpdatedAt }
        guard !due.isEmpty else { return }

        let deviceKey: String
        do {
            guard let storedKey = try deviceKeyStore.read(), !storedKey.isEmpty else {
                status = .retrying("Bark Device Key 尚未配置")
                return
            }
            deviceKey = storedKey
        } catch {
            status = .retrying(error.localizedDescription)
            return
        }

        for delivery in due where !Task.isCancelled {
            let notification = BarkNotification(
                title: delivery.title,
                body: delivery.body,
                group: delivery.group,
                url: delivery.deepLink,
                id: delivery.id
            )
            do {
                try await barkSender.send(notification, deviceKey: deviceKey, serverURL: barkServerURL)
                CompletionDetector.markDelivered(eventID: delivery.id, state: &monitorState, at: Date())
            } catch {
                var failed = delivery
                failed.attempts += 1
                failed.nextAttemptAt = retryPolicy.nextAttemptDate(
                    afterAttempt: failed.attempts,
                    now: Date()
                ) ?? .distantFuture
                monitorState.pending[delivery.id] = failed
                status = .retrying(ProcessLogRedactor.redact(error.localizedDescription))
            }
            persistState()
        }
    }

    private func persistState() {
        do {
            try persistence.save(monitorState)
        } catch {
            status = .retrying("无法保存完成监控状态：\(error.localizedDescription)")
        }
        updateCounts()
    }

    private func updateCounts() {
        pendingCount = monitorState.pending.count
        deliveredCount = monitorState.delivered.count
    }
}
