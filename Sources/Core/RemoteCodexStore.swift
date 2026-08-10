import Foundation

private struct ServerLocalState: Codable, Equatable {
    var savedProjectPaths: [String] = []
    var pinnedProjectPaths: [String] = []
    var pinnedThreadIDs: [String] = []
    var archivedProjectPaths: [String] = []
}

@MainActor
final class RemoteCodexStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile]
    @Published private(set) var activeServerID: UUID
    @Published var endpoint: ServerEndpoint
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isMainInterfaceVisible = false
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var threadDetails: [String: ThreadDetail] = [:]
    @Published private(set) var streamingItems: [String: [StreamingChatItem]] = [:]
    @Published private(set) var savedProjectPaths: [String] = []
    @Published private(set) var pinnedProjectPaths: Set<String> = []
    @Published private(set) var pinnedThreadIDs: Set<String> = []
    @Published private(set) var archivedProjectPaths: Set<String> = []
    @Published var requestedThreadID: String?
    @Published var errorMessage: String?

    let scheduledTasks: RemoteScheduledTaskStore

    private var client: (any CodexClientProtocol)?
    private let defaults: UserDefaults
    private var localStateByServerID: [UUID: ServerLocalState]
    private var activeThreadIDs: Set<String> = []
    private var isConnecting = false
    private var threadRefreshGeneration = 0
    private var notificationTask: Task<Void, Never>?
    private let remoteFileCache = NSCache<NSString, NSData>()

    init(
        client: (any CodexClientProtocol)? = nil,
        defaults: UserDefaults = .standard,
        scheduledTasks: RemoteScheduledTaskStore? = nil
    ) {
        self.defaults = defaults
        self.scheduledTasks = scheduledTasks ?? RemoteScheduledTaskStore()
        LegacyIOSReminderState.clear(defaults: defaults)
        let loadedServers = Self.loadServers(from: defaults)
        servers = loadedServers.servers
        activeServerID = loadedServers.activeServerID
        endpoint = loadedServers.servers.first(where: { $0.id == loadedServers.activeServerID })?.endpoint
            ?? loadedServers.servers[0].endpoint
        self.client = client
        remoteFileCache.totalCostLimit = 64 * 1_024 * 1_024
        localStateByServerID = Self.loadLocalStates(
            from: defaults,
            activeServerID: loadedServers.activeServerID
        )
        let activeLocalState = localStateByServerID[loadedServers.activeServerID] ?? ServerLocalState()
        savedProjectPaths = activeLocalState.savedProjectPaths
        pinnedProjectPaths = Set(activeLocalState.pinnedProjectPaths)
        pinnedThreadIDs = Set(activeLocalState.pinnedThreadIDs)
        archivedProjectPaths = Set(activeLocalState.archivedProjectPaths)
        requestedThreadID = defaults.string(forKey: StorageKey.pendingThreadID)
        if defaults.data(forKey: StorageKey.servers) == nil {
            persistServers()
        }
        if defaults.data(forKey: StorageKey.serverStates) == nil {
            persistCurrentLocalState()
        }
    }

    deinit {
        notificationTask?.cancel()
    }

    var allProjects: [ProjectSummary] {
        let allPaths = Set(savedProjectPaths).union(threads.map(\.cwd))
        return allPaths.map { path in
            let matching = threads.filter { $0.cwd == path }
            return ProjectSummary(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent,
                threadCount: matching.count,
                updatedAt: matching.map(\.updatedAt).max(),
                isPinned: pinnedProjectPaths.contains(path),
                isArchived: archivedProjectPaths.contains(path)
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

    var projects: [ProjectSummary] { allProjects.filter { !$0.isArchived } }

    var archivedProjects: [ProjectSummary] { allProjects.filter(\.isArchived) }

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
        await disconnect(userInitiated: false, clearRemoteState: true)
        connectionState = .connecting
        persistActiveServer()
        ConnectionPreferences.setAutoConnect(true, defaults: defaults)

        let client: any CodexClientProtocol = CodexWebSocketClient(endpoint: endpoint)
        self.client = client
        do {
            let server = try await client.connect()
            connectionState = .connected(server: server)
            isMainInterfaceVisible = true
            startListening(to: client)
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

    func disconnect(userInitiated: Bool = true, clearRemoteState: Bool = true) async {
        if userInitiated {
            ConnectionPreferences.setAutoConnect(false, defaults: defaults)
            isMainInterfaceVisible = false
        }
        notificationTask?.cancel()
        notificationTask = nil
        if let client { await client.disconnect() }
        client = nil
        activeThreadIDs.removeAll()
        connectionState = .disconnected
        streamingItems.removeAll()
        if clearRemoteState {
            threads.removeAll()
            models.removeAll()
            threadDetails.removeAll()
            scheduledTasks.reset()
            remoteFileCache.removeAllObjects()
        }
    }

    func updateActiveEndpoint(_ endpoint: ServerEndpoint) {
        self.endpoint = endpoint
        updateServerProfile(id: activeServerID, name: nil, endpoint: endpoint)
    }

    @discardableResult
    func addServer(name: String, endpoint: ServerEndpoint) -> UUID? {
        guard endpoint.isValid else {
            errorMessage = "请输入有效的 IP 与端口"
            return nil
        }
        let profile = ServerProfile(name: name, endpoint: endpoint)
        servers.append(profile)
        localStateByServerID[profile.id] = ServerLocalState()
        persistServers()
        persistLocalStates()
        return profile.id
    }

    func updateServer(id: UUID, name: String, endpoint: ServerEndpoint) async {
        guard endpoint.isValid else {
            errorMessage = "请输入有效的 IP 与端口"
            return
        }
        updateServerProfile(id: id, name: name, endpoint: endpoint)
        guard id == activeServerID else { return }
        await connect()
    }

    func switchServer(to id: UUID) async {
        guard let profile = servers.first(where: { $0.id == id }) else { return }
        guard id != activeServerID else {
            if !connectionState.isConnected { await connect() }
            return
        }
        persistCurrentLocalState()
        await disconnect(userInitiated: false, clearRemoteState: true)
        activeServerID = id
        endpoint = profile.endpoint
        restoreLocalState(for: id)
        persistActiveServer()
        await connect()
    }

    func removeServer(id: UUID) async {
        guard servers.count > 1 else {
            errorMessage = "至少需要保留一个 Codex Anywhere 服务端"
            return
        }
        guard servers.contains(where: { $0.id == id }) else { return }
        let wasActive = id == activeServerID
        let nextID = servers.first(where: { $0.id != id })?.id
        if wasActive { persistCurrentLocalState() }
        servers.removeAll { $0.id == id }
        localStateByServerID[id] = nil
        persistServers()
        persistLocalStates()
        guard wasActive, let nextID else { return }
        activeServerID = nextID
        endpoint = servers.first(where: { $0.id == nextID })?.endpoint ?? .fallback
        restoreLocalState(for: nextID)
        persistActiveServer()
        await disconnect(userInitiated: false, clearRemoteState: true)
        await connect()
    }

    private func updateServerProfile(id: UUID, name: String?, endpoint: ServerEndpoint) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        if let name { servers[index].name = name }
        servers[index].endpoint = endpoint
        if id == activeServerID { self.endpoint = endpoint }
        persistServers()
        persistEndpoint()
    }

    private func persistActiveServer() {
        if let index = servers.firstIndex(where: { $0.id == activeServerID }) {
            servers[index].endpoint = endpoint
        }
        persistServers()
        persistEndpoint()
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
                    for value in result["data"]?.arrayValue ?? [] {
                        guard var thread = CodexThread(json: value) else { continue }
                        thread.isArchived = archived
                        thread.isPinned = pinnedThreadIDs.contains(thread.id) || thread.isPinned
                        if thread.isPinned { pinnedThreadIDs.insert(thread.id) }
                        collectedByID[thread.id] = thread
                    }
                    cursor = result["nextCursor"]?.stringValue
                } while cursor != nil
            }
            guard generation == threadRefreshGeneration else { return }
            threads = collectedByID.values.sorted { $0.updatedAt > $1.updatedAt }
            persistCurrentLocalState()
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
    func createConversation(
        path: String,
        prompt: String,
        modelID: String?,
        effort: String?,
        waitForFirstTurn: Bool = true
    ) async throws -> String {
        guard let client else { throw CodexClientError.disconnected }
        var startParams: [String: JSONValue] = [
            "cwd": .string(path),
            "sandbox": .string("danger-full-access"),
            "approvalPolicy": .string("never"),
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
        if waitForFirstTurn {
            try await send(prompt: prompt, threadID: thread.id, modelID: modelID, effort: effort)
        } else {
            startFirstTurnInBackground(
                prompt: prompt,
                threadID: thread.id,
                modelID: modelID,
                effort: effort
            )
        }
        return thread.id
    }

    private func startFirstTurnInBackground(
        prompt: String,
        threadID: String,
        modelID: String?,
        effort: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(
                    prompt: prompt,
                    threadID: threadID,
                    modelID: modelID,
                    effort: effort
                )
            } catch {
                if await self.reconcileTimedOutFirstTurn(error, threadID: threadID) {
                    return
                }
                self.errorMessage = "会话已创建，但首条消息发送失败：\(error.localizedDescription)。可在会话中重新发送。"
            }
        }
    }

    private func reconcileTimedOutFirstTurn(_ error: Error, threadID: String) async -> Bool {
        guard case CodexClientError.transport(let message) = error,
              message == "Codex 请求超时",
              let client else { return false }
        do {
            let result = try await client.call(
                method: "thread/read",
                params: ["threadId": .string(threadID), "includeTurns": .bool(true)]
            )
            guard let json = result["thread"],
                  let detail = ThreadDetail(json: json),
                  detail.latestTurnID != nil || detail.thread.activity == .active else {
                return false
            }
            threadDetails[threadID] = detail
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index] = detail.thread
            }
            return true
        } catch {
            return false
        }
    }

    func send(prompt: String, threadID: String, modelID: String?, effort: String?) async throws {
        guard let client else { throw CodexClientError.disconnected }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let needsResume = !activeThreadIDs.contains(threadID)
        if needsResume, isThreadRunning(threadID) {
            await loadThread(threadID)
            if isThreadRunning(threadID) {
                throw CodexClientError.threadHasActiveWriter
            }
        }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(trimmed)])]),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object(["type": .string("dangerFullAccess")])
        ]
        if let modelID, !modelID.isEmpty { params["model"] = .string(modelID) }
        if let effort, !effort.isEmpty { params["effort"] = .string(effort) }
        streamingItems[threadID] = nil
        do {
            try await ThreadTurnStarter.start(
                threadID: threadID,
                params: params,
                resumeThread: needsResume
            ) { method, params in
                try await client.call(method: method, params: params)
            }
        } catch let error as CodexClientError where error.isActiveWriterConflict {
            await loadThread(threadID)
            throw CodexClientError.threadHasActiveWriter
        }
        activeThreadIDs.insert(threadID)
        await loadThread(threadID)
        await refreshThreads()
    }

    private func isThreadRunning(_ threadID: String) -> Bool {
        let activity = threadDetails[threadID]?.thread.activity
            ?? threads.first(where: { $0.id == threadID })?.activity
        return activity == .active
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

    func toggleThreadPin(_ threadID: String) {
        if pinnedThreadIDs.contains(threadID) {
            pinnedThreadIDs.remove(threadID)
        } else {
            pinnedThreadIDs.insert(threadID)
        }
        persistCurrentLocalState()
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].isPinned = pinnedThreadIDs.contains(threadID)
        }
    }

    func archiveThread(_ threadID: String) async {
        guard let client else { return }
        do {
            _ = try await client.call(method: "thread/archive", params: [
                "threadId": .string(threadID)
            ])
            await refreshThreads()
        } catch {
            report(error)
        }
    }

    func unarchiveThread(_ threadID: String) async {
        guard let client else { return }
        do {
            _ = try await client.call(method: "thread/unarchive", params: [
                "threadId": .string(threadID)
            ])
            await refreshThreads()
        } catch {
            report(error)
        }
    }

    func archiveProject(_ path: String) {
        archivedProjectPaths.insert(path)
        persistCurrentLocalState()
    }

    func unarchiveProject(_ path: String) {
        archivedProjectPaths.remove(path)
        persistCurrentLocalState()
    }

    func refreshRuntimeInfo() async {
        do {
            try await scheduledTasks.refreshRuntimeInfo(endpoint: endpoint)
        } catch {
            // Dash remains useful when an older Mac build has no info endpoint.
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
        persistCurrentLocalState()
    }

    func toggleProjectPin(_ path: String) {
        if pinnedProjectPaths.contains(path) {
            pinnedProjectPaths.remove(path)
        } else {
            pinnedProjectPaths.insert(path)
        }
        persistCurrentLocalState()
    }

    private func restoreLocalState(for serverID: UUID) {
        let state = localStateByServerID[serverID] ?? ServerLocalState()
        savedProjectPaths = state.savedProjectPaths
        pinnedProjectPaths = Set(state.pinnedProjectPaths)
        pinnedThreadIDs = Set(state.pinnedThreadIDs)
        archivedProjectPaths = Set(state.archivedProjectPaths)
        persistLegacyLocalStateMirror()
    }

    private func persistCurrentLocalState() {
        localStateByServerID[activeServerID] = ServerLocalState(
            savedProjectPaths: savedProjectPaths,
            pinnedProjectPaths: pinnedProjectPaths.sorted(),
            pinnedThreadIDs: pinnedThreadIDs.sorted(),
            archivedProjectPaths: archivedProjectPaths.sorted()
        )
        persistLocalStates()
        persistLegacyLocalStateMirror()
    }

    private func persistLocalStates() {
        let encodedByID = Dictionary(uniqueKeysWithValues: localStateByServerID.map {
            ($0.key.uuidString, $0.value)
        })
        if let data = try? JSONEncoder().encode(encodedByID) {
            defaults.set(data, forKey: StorageKey.serverStates)
        }
    }

    private func persistLegacyLocalStateMirror() {
        defaults.set(savedProjectPaths, forKey: StorageKey.projects)
        defaults.set(pinnedProjectPaths.sorted(), forKey: StorageKey.pinnedProjects)
        defaults.set(pinnedThreadIDs.sorted(), forKey: StorageKey.pinnedThreads)
        defaults.set(archivedProjectPaths.sorted(), forKey: StorageKey.archivedProjects)
    }

    private func persistEndpoint() {
        if let data = try? JSONEncoder().encode(endpoint) {
            defaults.set(data, forKey: StorageKey.endpoint)
        }
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: StorageKey.servers)
        }
        defaults.set(activeServerID.uuidString, forKey: StorageKey.activeServerID)
    }

    private static func loadServers(from defaults: UserDefaults) -> (servers: [ServerProfile], activeServerID: UUID) {
        if let data = defaults.data(forKey: StorageKey.servers),
           let servers = try? JSONDecoder().decode([ServerProfile].self, from: data),
           !servers.isEmpty {
            let activeID = defaults.string(forKey: StorageKey.activeServerID).flatMap(UUID.init)
                ?? servers[0].id
            let resolvedID = servers.contains(where: { $0.id == activeID }) ? activeID : servers[0].id
            return (servers, resolvedID)
        }

        let endpoint: ServerEndpoint
        if let data = defaults.data(forKey: StorageKey.endpoint),
           let savedEndpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: data) {
            endpoint = savedEndpoint
        } else {
            endpoint = .fallback
        }
        let profile = ServerProfile(name: "默认服务端", endpoint: endpoint)
        return ([profile], profile.id)
    }

    private static func loadLocalStates(
        from defaults: UserDefaults,
        activeServerID: UUID
    ) -> [UUID: ServerLocalState] {
        if let data = defaults.data(forKey: StorageKey.serverStates),
           let encodedByID = try? JSONDecoder().decode([String: ServerLocalState].self, from: data) {
            let states = Dictionary(uniqueKeysWithValues: encodedByID.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            if !states.isEmpty { return states }
        }

        return [activeServerID: ServerLocalState(
            savedProjectPaths: defaults.stringArray(forKey: StorageKey.projects) ?? [],
            pinnedProjectPaths: defaults.stringArray(forKey: StorageKey.pinnedProjects) ?? [],
            pinnedThreadIDs: defaults.stringArray(forKey: StorageKey.pinnedThreads) ?? [],
            archivedProjectPaths: defaults.stringArray(forKey: StorageKey.archivedProjects) ?? []
        )]
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
    static let servers = "codeanywhere.servers"
    static let activeServerID = "codeanywhere.activeServerID"
    static let serverStates = "codeanywhere.serverStates"
    static let autoConnect = "codeanywhere.autoConnect"
    static let projects = "codeanywhere.projects"
    static let pinnedProjects = "codeanywhere.pinnedProjects"
    static let pinnedThreads = "codeanywhere.pinnedThreads"
    static let archivedProjects = "codeanywhere.archivedProjects"
    static let pendingThreadID = "codeanywhere.pendingThreadID"
    static let appearance = "codeanywhere.appearance"
    static let defaultModel = "codeanywhere.defaultModel"
    static let defaultReasoningEffort = "codeanywhere.defaultReasoningEffort"
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

enum LegacyIOSReminderState {
    private static let keys = [
        "codeanywhere.watchedThreads",
        "codeanywhere.backgroundRefreshScheduledAt",
        "codeanywhere.backgroundRefreshCheckedAt",
        "codeanywhere.backgroundRefreshError"
    ]

    static func clear(defaults: UserDefaults = .standard) {
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
}
