import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class RemoteCodexStore: ObservableObject {
    @Published var endpoint: ServerEndpoint
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var threadDetails: [String: ThreadDetail] = [:]
    @Published private(set) var streamingText: [String: String] = [:]
    @Published private(set) var savedProjectPaths: [String] = []
    @Published var requestedThreadID: String?
    @Published var errorMessage: String?

    private var client: (any CodexClientProtocol)?
    private let defaults: UserDefaults
    private var activeThreadIDs: Set<String> = []
    private var isConnecting = false
    private var notificationTask: Task<Void, Never>?
    private var notificationOpenTask: Task<Void, Never>?
    private let remoteFileCache = NSCache<NSString, NSData>()

    init(client: (any CodexClientProtocol)? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = Self.loadEndpoint(from: defaults)
        self.client = client
        remoteFileCache.totalCostLimit = 64 * 1_024 * 1_024
        savedProjectPaths = defaults.stringArray(forKey: StorageKey.projects) ?? []
        requestedThreadID = defaults.string(forKey: StorageKey.pendingThreadID)
        notificationOpenTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .openCodexThread) {
                guard let self, let threadID = notification.object as? String else { continue }
                self.requestedThreadID = threadID
            }
        }
    }

    deinit {
        notificationTask?.cancel()
        notificationOpenTask?.cancel()
    }

    var projects: [ProjectSummary] {
        let allPaths = Set(savedProjectPaths).union(threads.map(\.cwd))
        return allPaths.map { path in
            let matching = threads.filter { $0.cwd == path }
            return ProjectSummary(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent,
                threadCount: matching.count,
                updatedAt: matching.map(\.updatedAt).max()
            )
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func connectIfConfigured() async {
        guard ConnectionPreferences.shouldAutoConnect(defaults: defaults),
              !connectionState.isConnected,
              !isConnecting else { return }
        await connect()
    }

    func connect() async {
        guard !isConnecting else { return }
        guard endpoint.isValid else {
            connectionState = .failed(message: "请输入有效的 IP 与端口")
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        await disconnect(userInitiated: false)
        connectionState = .connecting
        persistEndpoint()
        ConnectionPreferences.setAutoConnect(true, defaults: defaults)

        let client: any CodexClientProtocol = CodexWebSocketClient(endpoint: endpoint)
        self.client = client
        do {
            let server = try await client.connect()
            connectionState = .connected(server: server)
            startListening(to: client)
            _ = await NotificationManager.shared.requestAuthorization()
            async let threadRefresh: Void = refreshThreads()
            async let modelRefresh: Void = refreshModels()
            _ = await (threadRefresh, modelRefresh)
        } catch {
            connectionState = .failed(message: error.localizedDescription)
            errorMessage = error.localizedDescription
            await client.disconnect()
            self.client = nil
        }
    }

    func disconnect(userInitiated: Bool = true) async {
        if userInitiated {
            ConnectionPreferences.setAutoConnect(false, defaults: defaults)
        }
        notificationTask?.cancel()
        notificationTask = nil
        if let client { await client.disconnect() }
        client = nil
        activeThreadIDs.removeAll()
        connectionState = .disconnected
        streamingText.removeAll()
    }

    func refreshThreads() async {
        guard let client else { return }
        do {
            var collectedByID: [String: CodexThread] = [:]
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
                    for thread in (result["data"]?.arrayValue ?? []).compactMap(CodexThread.init(json:)) {
                        collectedByID[thread.id] = thread
                    }
                    cursor = result["nextCursor"]?.stringValue
                } while cursor != nil
            }
            threads = collectedByID.values.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            report(error)
        }
    }

    func refreshModels() async {
        guard let client else { return }
        do {
            let result = try await client.call(method: "model/list", params: ["limit": .number(100)])
            models = (result["data"]?.arrayValue ?? []).compactMap(CodexModel.init(json:))
        } catch {
            report(error)
        }
    }

    func loadThread(_ threadID: String) async {
        guard let client else { return }
        do {
            let result = try await client.call(
                method: "thread/read",
                params: ["threadId": .string(threadID), "includeTurns": .bool(true)]
            )
            guard let json = result["thread"], let detail = ThreadDetail(json: json) else {
                throw CodexClientError.malformedResponse
            }
            threadDetails[threadID] = detail
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index] = detail.thread
            }
        } catch {
            report(error)
        }
    }

    @discardableResult
    func createConversation(path: String, prompt: String, modelID: String?, effort: String?) async throws -> String {
        guard let client else { throw CodexClientError.disconnected }
        var startParams: [String: JSONValue] = [
            "cwd": .string(path),
            "sandbox": .string("workspace-write"),
            "approvalPolicy": .string("on-request"),
            "threadSource": .string("codeanywhere-ios")
        ]
        if let modelID, !modelID.isEmpty { startParams["model"] = .string(modelID) }
        let result = try await client.call(method: "thread/start", params: startParams)
        guard let threadJSON = result["thread"], let thread = CodexThread(json: threadJSON) else {
            throw CodexClientError.malformedResponse
        }
        saveProjectPath(path)
        threads.insert(thread, at: 0)
        activeThreadIDs.insert(thread.id)
        try await send(prompt: prompt, threadID: thread.id, modelID: modelID, effort: effort)
        return thread.id
    }

    func send(prompt: String, threadID: String, modelID: String?, effort: String?) async throws {
        guard let client else { throw CodexClientError.disconnected }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(trimmed)])])
        ]
        if let modelID, !modelID.isEmpty { params["model"] = .string(modelID) }
        if let effort, !effort.isEmpty { params["effort"] = .string(effort) }
        let needsResume = !activeThreadIDs.contains(threadID)
        try await ThreadTurnStarter.start(
            threadID: threadID,
            params: params,
            resumeThread: needsResume
        ) { method, params in
            try await client.call(method: method, params: params)
        }
        activeThreadIDs.insert(threadID)
        BackgroundWatchStore.add(threadID: threadID, title: threads.first(where: { $0.id == threadID })?.title ?? "Codex 对话")
        AppDelegate.scheduleBackgroundRefresh()
        await loadThread(threadID)
        await refreshThreads()
    }

    func interrupt(threadID: String) async {
        guard let client, let turnID = threadDetails[threadID]?.latestTurnID else { return }
        do {
            _ = try await client.call(method: "turn/interrupt", params: [
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        } catch {
            report(error)
        }
    }

    func createProject(path: String) async throws {
        guard let client else { throw CodexClientError.disconnected }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw CodexClientError.transport("项目路径必须是桌面端的绝对路径")
        }
        _ = try await client.call(method: "fs/createDirectory", params: [
            "path": .string(trimmed),
            "recursive": .bool(true)
        ])
        saveProjectPath(trimmed)
    }

    func imageData(atRemotePath path: String) async throws -> Data {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw CodexClientError.transport("图片路径无效")
        }
        if let cached = remoteFileCache.object(forKey: trimmed as NSString) {
            return cached as Data
        }
        guard let client else { throw CodexClientError.disconnected }
        let result = try await client.call(method: "fs/readFile", params: ["path": .string(trimmed)])
        guard let encoded = result["dataBase64"]?.stringValue,
              encoded.utf8.count <= ChatImagePolicy.maximumEncodedDataURLBytes else {
            throw CodexClientError.transport("图片超过 25 MB，无法预览")
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            Data(base64Encoded: encoded)
        }.value
        guard let data = decoded else {
            throw CodexClientError.malformedResponse
        }
        guard data.count <= ChatImagePolicy.maximumDecodedImageBytes else {
            throw CodexClientError.transport("图片超过 25 MB，无法预览")
        }
        remoteFileCache.setObject(data as NSData, forKey: trimmed as NSString, cost: data.count)
        return data
    }

    private func startListening(to client: any CodexClientProtocol) {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            for await notification in client.notifications {
                guard let self, !Task.isCancelled else { return }
                await self.handle(notification)
            }
        }
    }

    private func handle(_ notification: RPCNotification) async {
        let threadID = notification.params["threadId"]?.stringValue
        switch notification.method {
        case "item/agentMessage/delta":
            if let threadID, let delta = notification.params["delta"]?.stringValue {
                streamingText[threadID, default: ""] += delta
            }
        case "item/completed":
            if let threadID {
                if notification.params["item"]?["type"]?.stringValue == "agentMessage" {
                    streamingText[threadID] = nil
                }
                await loadThread(threadID)
            }
        case "turn/completed":
            guard let threadID else { return }
            streamingText[threadID] = nil
            await loadThread(threadID)
            await refreshThreads()
            if BackgroundWatchStore.remove(threadID: threadID) {
                let title = threads.first(where: { $0.id == threadID })?.title ?? "Codex 对话"
                try? await NotificationManager.shared.notifyCompletion(title: title, threadID: threadID)
            }
        case "transport/closed":
            connectionState = .failed(message: notification.params.stringValue ?? "连接已断开")
        default:
            break
        }
    }

    private func saveProjectPath(_ path: String) {
        guard !savedProjectPaths.contains(path) else { return }
        savedProjectPaths.append(path)
        defaults.set(savedProjectPaths, forKey: StorageKey.projects)
    }

    private func persistEndpoint() {
        if let data = try? JSONEncoder().encode(endpoint) {
            defaults.set(data, forKey: StorageKey.endpoint)
        }
    }

    private static func loadEndpoint(from defaults: UserDefaults) -> ServerEndpoint {
        guard let data = defaults.data(forKey: StorageKey.endpoint),
              let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: data) else {
            return .fallback
        }
        return endpoint
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func consumeRequestedThread() {
        requestedThreadID = nil
        defaults.removeObject(forKey: StorageKey.pendingThreadID)
    }
}

enum StorageKey {
    static let endpoint = "codeanywhere.endpoint"
    static let autoConnect = "codeanywhere.autoConnect"
    static let projects = "codeanywhere.projects"
    static let watchedThreads = "codeanywhere.watchedThreads"
    static let pendingThreadID = "codeanywhere.pendingThreadID"
    static let appearance = "codeanywhere.appearance"
}

enum ConnectionPreferences {
    static func shouldAutoConnect(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.data(forKey: StorageKey.endpoint) != nil else { return false }
        guard defaults.object(forKey: StorageKey.autoConnect) != nil else {
            return true
        }
        return defaults.bool(forKey: StorageKey.autoConnect)
    }

    static func setAutoConnect(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: StorageKey.autoConnect)
    }
}

extension Notification.Name {
    static let openCodexThread = Notification.Name("codeanywhere.openCodexThread")
}

struct WatchedThread: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

enum BackgroundWatchStore {
    static func all(defaults: UserDefaults = .standard) -> [WatchedThread] {
        guard let data = defaults.data(forKey: StorageKey.watchedThreads) else { return [] }
        return (try? JSONDecoder().decode([WatchedThread].self, from: data)) ?? []
    }

    static func add(threadID: String, title: String, defaults: UserDefaults = .standard) {
        var items = all(defaults: defaults).filter { $0.id != threadID }
        items.append(WatchedThread(id: threadID, title: title))
        save(items, defaults: defaults)
    }

    @discardableResult
    static func remove(threadID: String, defaults: UserDefaults = .standard) -> Bool {
        let items = all(defaults: defaults)
        let filtered = items.filter { $0.id != threadID }
        guard filtered.count != items.count else { return false }
        save(filtered, defaults: defaults)
        return true
    }

    private static func save(_ items: [WatchedThread], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(items), forKey: StorageKey.watchedThreads)
    }
}
