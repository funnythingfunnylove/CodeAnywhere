import Foundation

public struct DaemonPollResult: Equatable, Sendable {
    public let threadCount: Int
    public let pendingCount: Int
    public let deliveredCount: Int
}

public actor CodeAnywhereDaemon {
    public let configuration: CodeAnywhereConfiguration
    public let supervisor: CodexProcessSupervisor

    private var client: CodexWebSocketClient?
    private var state: CompletionState
    private let stateStore: FileCompletionStateStore
    private let barkClient: BarkClient
    private var titles: [String: String] = [:]
    private var stopped = false

    public init(
        configuration: CodeAnywhereConfiguration,
        supervisor: CodexProcessSupervisor = CodexProcessSupervisor()
    ) {
        self.configuration = configuration
        self.supervisor = supervisor
        self.stateStore = FileCompletionStateStore(url: configuration.resolvedStateURL())
        self.state = stateStore.load()
        self.barkClient = BarkClient()
    }

    public func start() async throws {
        stopped = false
        if configuration.server.autoStart && !supervisor.isRunning {
            _ = try supervisor.start(configuration: configuration.server)
        }
        let endpoint = CodexEndpoint(
            host: "127.0.0.1",
            port: configuration.server.port,
            token: configuration.server.token
        )
        let client = CodexWebSocketClient(endpoint: endpoint)
        var lastError: Error?
        for attempt in 0..<50 {
            do {
                try await client.connect()
                lastError = nil
                break
            } catch {
                lastError = error
                if !supervisor.isRunning || attempt == 49 { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if let lastError {
            // A failed WebSocket handshake must not leave the app-server and
            // its capability token behind when this API is used without the
            // CLI wrapper.
            supervisor.stop()
            throw lastError
        }
        self.client = client
        Task { [weak self, weak client] in
            guard let self, let client else { return }
            for await notification in client.notifications {
                await self.handle(notification)
            }
        }
    }

    public func stop() async {
        stopped = true
        if let client { await client.disconnect() }
        client = nil
        supervisor.stop()
    }

    public func probe() async throws -> (version: String?, threadCount: Int) {
        guard let client else { throw CodexClientError.disconnected }
        let models = try await client.call(method: "model/list", params: [:])
        let threads = try await client.call(method: "thread/list", params: [
            "limit": .number(1),
            "sortKey": .string("updated_at"),
            "sortDirection": .string("desc"),
            "modelProviders": .array([]),
            "archived": .bool(false)
        ])
        return (
            version: models["data"]?.arrayValue?.first?["id"]?.stringValue,
            threadCount: threads["data"]?.arrayValue?.count ?? 0
        )
    }

    public func pollOnce() async throws -> DaemonPollResult {
        guard let client else { throw CodexClientError.disconnected }
        var listed: [String: MonitoredThreadSnapshot] = [:]
        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = [
                    "limit": .number(100),
                    "sortKey": .string("updated_at"),
                    "sortDirection": .string("desc"),
                    "modelProviders": .array([]),
                    "archived": .bool(archived)
                ]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try await client.call(method: "thread/list", params: params)
                for item in result["data"]?.arrayValue ?? [] {
                    if let snapshot = MonitoredThreadSnapshot(json: item) {
                        listed[snapshot.id] = snapshot
                        titles[snapshot.id] = snapshot.title
                    }
                }
                cursor = result["nextCursor"]?.stringValue
                if cursor?.isEmpty == true { cursor = nil }
            } while cursor != nil
        }

        var detailed: [MonitoredThreadSnapshot] = []
        for snapshot in listed.values where snapshot.updatedAt > state.baseline || state.active.contains(snapshot.id) {
            let result = try await client.call(method: "thread/read", params: [
                "threadId": .string(snapshot.id), "includeTurns": .bool(true)
            ])
            if let thread = result["thread"], let detail = MonitoredThreadSnapshot(json: thread) {
                detailed.append(detail)
            }
        }
        CompletionDetector.observe(
            snapshots: detailed,
            state: &state,
            now: Date(),
            maximumAttempts: configuration.monitor.maximumDeliveryAttempts
        )
        try stateStore.save(state)
        try await deliverDueNotifications()
        return DaemonPollResult(threadCount: listed.count, pendingCount: state.pending.count, deliveredCount: state.delivered.count)
    }

    public func run() async {
        while !stopped {
            do { _ = try await pollOnce() }
            catch {
                // Disconnect during an intentional shutdown is expected and
                // should not look like a daemon fault in systemd logs.
                if !stopped, (error as? CodexClientError) != .disconnected {
                    print("[WARN] 轮询失败：\(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .seconds(configuration.monitor.pollIntervalSeconds))
        }
    }

    private func handle(_ notification: CodexNotification) async {
        guard notification.method == "turn/completed",
              let event = CodexServerEventParser.parse(.object([
                "method": .string(notification.method), "params": notification.params
              ])) else { return }
        if case .turnTerminated(let event) = event {
            CompletionDetector.observe(event, state: &state, title: titles[event.threadID] ?? "Codex 对话")
            try? stateStore.save(state)
            try? await deliverDueNotifications()
        }
    }

    private func deliverDueNotifications() async throws {
        guard configuration.bark.enabled else { return }
        guard let deviceKey = ProcessInfo.processInfo.environment[configuration.bark.deviceKeyEnv], !deviceKey.isEmpty else {
            print("[WARN] Bark 已启用但环境变量 \(configuration.bark.deviceKeyEnv) 未设置；保留待发送记录")
            return
        }
        let now = Date()
        for pending in state.pending.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard pending.nextAttemptAt <= now,
                  pending.attempts < configuration.monitor.maximumDeliveryAttempts else { continue }
            let notification = BarkNotification(
                title: pending.title,
                body: pending.detail.map { "\(pending.body)\n错误：\($0)" } ?? pending.body,
                group: configuration.bark.group,
                url: pending.deepLink,
                id: pending.id
            )
            do {
                try await barkClient.send(notification, deviceKey: deviceKey, serverURL: configuration.bark.serverURL)
                state.pending.removeValue(forKey: pending.id)
                state.delivered[pending.id] = Date()
                try stateStore.save(state)
                print("[INFO] Bark 已接受：\(pending.title) \(String(pending.threadID.prefix(8)))")
            } catch {
                var retry = pending
                retry.attempts += 1
                retry.nextAttemptAt = Date().addingTimeInterval(min(300, 15 * pow(2, Double(max(0, retry.attempts - 1)))))
                state.pending[pending.id] = retry
                try stateStore.save(state)
                print("[WARN] Bark 发送失败（第 \(retry.attempts) 次）：\(error.localizedDescription)")
            }
        }
    }
}
