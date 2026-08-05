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
    @Published private(set) var streamingItems: [String: [StreamingChatItem]] = [:]
    @Published private(set) var savedProjectPaths: [String] = []
    @Published private(set) var pinnedProjectPaths: Set<String> = []
    @Published var requestedThreadID: String?
    @Published var errorMessage: String?

    private var client: (any CodexClientProtocol)?
    private let defaults: UserDefaults
    private var activeThreadIDs: Set<String> = []
    private var isConnecting = false
    private var threadRefreshGeneration = 0
    private var notificationTask: Task<Void, Never>?
    private var notificationOpenTask: Task<Void, Never>?
    private let remoteFileCache = NSCache<NSString, NSData>()

    init(client: (any CodexClientProtocol)? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = Self.loadEndpoint(from: defaults)
        self.client = client
        remoteFileCache.totalCostLimit = 64 * 1_024 * 1_024
        savedProjectPaths = defaults.stringArray(forKey: StorageKey.projects) ?? []
        pinnedProjectPaths = Set(defaults.stringArray(forKey: StorageKey.pinnedProjects) ?? [])
        requestedThreadID = defaults.string(forKey: StorageKey.pendingThreadID)
        notificationOpenTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .openCodexThread) {
                guard let self, let threadID = notification.object as? String else { continue }
                await self.requestOpenThread(threadID)
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
                updatedAt: matching.map(\.updatedAt).max(),
                isPinned: pinnedProjectPaths.contains(path)
            )
        }
        .sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt {
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func connectIfConfigured() async {
        guard ConnectionPreferences.shouldAutoConnect(defaults: defaults),
              !connectionState.isConnected,
              !isConnecting else { return }
        await connect()
    }

    func requestOpenThread(_ threadID: String) async {
        requestedThreadID = threadID
        defaults.set(threadID, forKey: StorageKey.pendingThreadID)

        if !connectionState.isConnected,
           defaults.data(forKey: StorageKey.endpoint) != nil {
            await connect()
        }
        if connectionState.isConnected {
            await refreshThreads()
        }
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
        streamingItems.removeAll()
    }

    func refreshThreads() async {
        guard let client else { return }
        threadRefreshGeneration += 1
        let generation = threadRefreshGeneration
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
            guard generation == threadRefreshGeneration else { return }
            threads = collectedByID.values.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            guard generation == threadRefreshGeneration else { return }
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
        streamingItems[threadID] = nil
        BackgroundWatchStore.add(
            threadID: threadID,
            title: threads.first(where: { $0.id == threadID })?.title ?? "Codex 对话",
            defaults: defaults
        )
        notifyBackgroundWatchStateChanged()
        do {
            try await ThreadTurnStarter.start(
                threadID: threadID,
                params: params,
                resumeThread: needsResume
            ) { method, params in
                try await client.call(method: method, params: params)
            }
        } catch {
            BackgroundWatchStore.remove(threadID: threadID, defaults: defaults)
            notifyBackgroundWatchStateChanged()
            throw error
        }
        activeThreadIDs.insert(threadID)
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

    func handle(_ notification: RPCNotification) async {
        let threadID = notification.params["threadId"]?.stringValue
        switch notification.method {
        case "item/started":
            guard let threadID,
                  let item = notification.params["item"],
                  let itemID = item["id"]?.stringValue,
                  let type = item["type"]?.stringValue else { return }
            switch type {
            case "agentMessage":
                upsertStreamingItem(
                    threadID: threadID,
                    itemID: itemID,
                    kind: .assistant,
                    initialPrimaryText: item["text"]?.stringValue ?? ""
                )
            case "reasoning", "plan":
                upsertStreamingItem(threadID: threadID, itemID: itemID, kind: .reasoning)
            case "commandExecution":
                upsertStreamingItem(
                    threadID: threadID,
                    itemID: itemID,
                    kind: .command,
                    initialPrimaryText: item["command"]?.stringValue ?? ""
                )
            default:
                break
            }
        case "item/agentMessage/delta":
            appendStreamingDelta(from: notification, threadID: threadID, kind: .assistant, channel: .primary)
        case "item/reasoning/summaryTextDelta":
            appendStreamingDelta(from: notification, threadID: threadID, kind: .reasoning, channel: .primary)
        case "item/reasoning/summaryPartAdded":
            guard let threadID,
                  let itemID = notification.params["itemId"]?.stringValue,
                  (notification.params["summaryIndex"]?.intValue ?? 0) > 0 else { return }
            upsertStreamingItem(threadID: threadID, itemID: itemID, kind: .reasoning)
            if streamingItems[threadID]?.first(where: { $0.id == itemID })?.primaryText.isEmpty == false {
                appendStreamingText("\n", threadID: threadID, itemID: itemID, channel: .primary)
            }
        case "item/reasoning/textDelta":
            appendStreamingDelta(from: notification, threadID: threadID, kind: .reasoning, channel: .secondary)
        case "item/plan/delta":
            appendStreamingDelta(from: notification, threadID: threadID, kind: .reasoning, channel: .primary)
        case "item/commandExecution/outputDelta":
            appendStreamingDelta(from: notification, threadID: threadID, kind: .command, channel: .secondary)
        case "item/completed":
            if let threadID {
                let itemID = notification.params["item"]?["id"]?.stringValue
                await loadThread(threadID)
                if let itemID { removeStreamingItem(threadID: threadID, itemID: itemID) }
            }
        case "turn/completed":
            guard let threadID else { return }
            if let watched = BackgroundWatchStore.take(threadID: threadID, defaults: defaults) {
                do {
                    try await NotificationManager.shared.notifyCompletion(title: watched.title, threadID: threadID)
                    notifyBackgroundWatchStateChanged()
                } catch {
                    BackgroundWatchStore.add(threadID: watched.id, title: watched.title, defaults: defaults)
                    notifyBackgroundWatchStateChanged()
                    report(error)
                }
            }
            await loadThread(threadID)
            streamingItems[threadID] = nil
            await refreshThreads()
        case "transport/closed":
            connectionState = .failed(message: notification.params.stringValue ?? "连接已断开")
        default:
            break
        }
    }

    private func appendStreamingDelta(
        from notification: RPCNotification,
        threadID: String?,
        kind: StreamingChatItemKind,
        channel: StreamingChatItemChannel
    ) {
        guard let threadID,
              let itemID = notification.params["itemId"]?.stringValue,
              let delta = notification.params["delta"]?.stringValue,
              !delta.isEmpty else { return }
        upsertStreamingItem(threadID: threadID, itemID: itemID, kind: kind)
        appendStreamingText(delta, threadID: threadID, itemID: itemID, channel: channel)
    }

    private func appendStreamingText(
        _ text: String,
        threadID: String,
        itemID: String,
        channel: StreamingChatItemChannel
    ) {
        guard var items = streamingItems[threadID],
              let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].append(text, to: channel)
        streamingItems[threadID] = items
    }

    private func upsertStreamingItem(
        threadID: String,
        itemID: String,
        kind: StreamingChatItemKind,
        initialPrimaryText: String = ""
    ) {
        var items = streamingItems[threadID] ?? []
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            if items[index].primaryText.isEmpty, !initialPrimaryText.isEmpty {
                items[index].primaryText = initialPrimaryText
            }
        } else {
            items.append(
                StreamingChatItem(
                    id: itemID,
                    kind: kind,
                    primaryText: initialPrimaryText
                )
            )
        }
        streamingItems[threadID] = items
    }

    private func removeStreamingItem(threadID: String, itemID: String) {
        guard var items = streamingItems[threadID] else { return }
        items.removeAll { $0.id == itemID }
        streamingItems[threadID] = items.isEmpty ? nil : items
    }

    private func saveProjectPath(_ path: String) {
        guard !savedProjectPaths.contains(path) else { return }
        savedProjectPaths.append(path)
        defaults.set(savedProjectPaths, forKey: StorageKey.projects)
    }

    func toggleProjectPin(_ path: String) {
        if pinnedProjectPaths.contains(path) {
            pinnedProjectPaths.remove(path)
        } else {
            pinnedProjectPaths.insert(path)
        }
        defaults.set(pinnedProjectPaths.sorted(), forKey: StorageKey.pinnedProjects)
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

    private func notifyBackgroundWatchStateChanged() {
        guard defaults === UserDefaults.standard else { return }
        AppDelegate.backgroundWatchStateChanged()
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
    static let pinnedProjects = "codeanywhere.pinnedProjects"
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
    private static let lock = NSLock()

    static func all(defaults: UserDefaults = .standard) -> [WatchedThread] {
        lock.lock()
        defer { lock.unlock() }
        return load(defaults: defaults)
    }

    private static func load(defaults: UserDefaults) -> [WatchedThread] {
        guard let data = defaults.data(forKey: StorageKey.watchedThreads) else { return [] }
        return (try? JSONDecoder().decode([WatchedThread].self, from: data)) ?? []
    }

    static func add(threadID: String, title: String, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        var items = load(defaults: defaults).filter { $0.id != threadID }
        items.append(WatchedThread(id: threadID, title: title))
        save(items, defaults: defaults)
    }

    @discardableResult
    static func remove(threadID: String, defaults: UserDefaults = .standard) -> Bool {
        take(threadID: threadID, defaults: defaults) != nil
    }

    @discardableResult
    static func take(threadID: String, defaults: UserDefaults = .standard) -> WatchedThread? {
        lock.lock()
        defer { lock.unlock() }
        let items = load(defaults: defaults)
        guard let item = items.first(where: { $0.id == threadID }) else { return nil }
        let filtered = items.filter { $0.id != threadID }
        save(filtered, defaults: defaults)
        return item
    }

    private static func save(_ items: [WatchedThread], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(items), forKey: StorageKey.watchedThreads)
    }
}
