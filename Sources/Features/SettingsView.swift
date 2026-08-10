import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @AppStorage(StorageKey.appearance) private var appearanceValue = AppAppearance.system.rawValue
    @AppStorage(StorageKey.defaultModel) private var defaultModelID = ""
    @AppStorage(StorageKey.defaultReasoningEffort) private var defaultReasoningEffort = OpenAIReasoningLevel.medium.rawValue

    private var selectedDefaultModel: CodexModel? {
        NewConversationDefaults.preferredModel(
            in: store.models,
            preferredModelID: defaultModelID
        )
    }

    var body: some View {
        ZStack {
            AmbientBackground()
            Form {
                ServerProfilesSettingsSection()

                Section("连接") {
                    LabeledContent("IP 地址", value: store.endpoint.host)
                    LabeledContent("端口", value: String(store.endpoint.port))
                    if case .connected(let server) = store.connectionState {
                        LabeledContent("服务端", value: server)
                    } else {
                        LabeledContent("状态", value: store.connectionState == .connecting ? "连接中…" : "未连接")
                    }
                    Button("断开连接", role: .destructive) {
                        Task { await store.disconnect() }
                    }
                }
                Section("Bark 提醒") {
                    LabeledContent("提醒来源", value: "CodeAnywhere Mac")
                    LabeledContent("通知方式", value: "Bark")
                    Text("完成提醒全部由 Mac 伴侣监控并通过 Bark 发送；点击 Bark 通知可打开对应对话。Mac App 未运行或 Bark 尚未配置时不会收到离线提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if store.models.isEmpty {
                        Label("暂时没有可用模型", systemImage: "cpu")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("默认模型", selection: $defaultModelID) {
                            Text("服务端推荐").tag("")
                            ForEach(store.models) { model in
                                Text(model.displayName).tag(model.model)
                            }
                        }

                        if selectedDefaultModel != nil {
                            Picker("默认思考级别", selection: $defaultReasoningEffort) {
                                ForEach(OpenAIReasoningLevel.allCases) { level in
                                    Label(level.title, systemImage: level.systemImage)
                                        .tag(level.rawValue)
                                }
                            }
                        } else {
                            LabeledContent("默认思考级别", value: OpenAIReasoningLevel.medium.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("新对话默认值")
                } footer: {
                    Text("创建新对话时会自动带入这些选项，仍可在开始前单独调整。")
                }
                Section("外观") {
                    Picker("显示模式", selection: $appearanceValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text((AppAppearance(rawValue: appearanceValue) ?? .system).description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("协议", value: "Codex app-server JSON-RPC v2")
                    LabeledContent("版本", value: versionText)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("设置")
        .onAppear { normalizeConversationDefaults() }
        .onChange(of: store.models) { _, _ in
            normalizeConversationDefaults()
        }
        .onChange(of: defaultModelID) { _, _ in
            normalizeReasoningEffort()
        }
    }

    private func normalizeConversationDefaults() {
        guard !store.models.isEmpty else { return }
        if !defaultModelID.isEmpty,
           !store.models.contains(where: { $0.model == defaultModelID }) {
            defaultModelID = ""
            return
        }
        normalizeReasoningEffort()
    }

    private func normalizeReasoningEffort() {
        defaultReasoningEffort = OpenAIReasoningLevel.resolve(defaultReasoningEffort)?.rawValue
            ?? OpenAIReasoningLevel.medium.rawValue
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

private struct ServerProfilesSettingsSection: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var showingAddServer = false
    @State private var editingServer: ServerProfile?
    @State private var serverToDelete: ServerProfile?

    var body: some View {
        Section {
            Picker("当前服务端", selection: activeServerBinding) {
                ForEach(store.servers) { server in
                    Text(server.displayName).tag(server.id)
                }
            }

            ForEach(store.servers) { server in
                ServerProfileRow(
                    server: server,
                    isActive: server.id == store.activeServerID,
                    isConnected: store.connectionState.isConnected,
                    canDelete: store.servers.count > 1,
                    onSelect: { Task { await store.switchServer(to: server.id) } },
                    onEdit: { editingServer = server },
                    onDelete: { serverToDelete = server }
                )
            }
        } header: {
            HStack {
                Text("Codex Anywhere 服务端")
                Spacer()
                Button {
                    showingAddServer = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .textCase(nil)
            }
        } footer: {
            Text("可保存多台局域网 CodeAnywhere，切换后会重新加载对应服务端的对话与模型。")
        }
        .sheet(isPresented: $showingAddServer) {
            ServerProfileEditorView()
        }
        .sheet(item: $editingServer) { server in
            ServerProfileEditorView(profile: server)
        }
        .alert("删除服务端？", isPresented: Binding(
            get: { serverToDelete != nil },
            set: { if !$0 { serverToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let server = serverToDelete {
                    Task { await store.removeServer(id: server.id) }
                }
                serverToDelete = nil
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(verbatim: "“\(serverToDelete?.displayName ?? "服务端")”的连接配置将从本机移除。")
        }
    }

    private var activeServerBinding: Binding<UUID> {
        Binding(
            get: { store.activeServerID },
            set: { id in Task { await store.switchServer(to: id) } }
        )
    }
}

private struct ServerProfileRow: View {
    let server: ServerProfile
    let isActive: Bool
    let isConnected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(server.displayAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if isActive {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .accessibilityLabel(isConnected ? "当前已连接" : "当前服务端")
            }
            Menu {
                Button("编辑", systemImage: "pencil", action: onEdit)
                if canDelete {
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("管理 \(server.displayName)")
        }
    }
}

private struct ServerProfileEditorView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss

    let profile: ServerProfile?
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var isSaving = false

    init(profile: ServerProfile? = nil) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.endpoint.host ?? "")
        _port = State(initialValue: profile.map { String($0.endpoint.port) } ?? "4500")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务端信息") {
                    TextField("名称，例如：家里 Debian", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("IP 地址或主机名", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                }
                Section {
                    Text("服务端需要运行 CodeAnywhere headless daemon，并在同一局域网提供 Codex app-server。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(profile == nil ? "添加服务端" : "编辑服务端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { save() }
                        .disabled(!isValid || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var isValid: Bool {
        ServerEndpoint(host: host, port: Int(port) ?? 0).isValid
    }

    private func save() {
        let endpoint = ServerEndpoint(host: host, port: Int(port) ?? 0)
        guard endpoint.isValid else { return }
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "CodeAnywhere" : name
        isSaving = true
        Task {
            if let profile {
                await store.updateServer(id: profile.id, name: resolvedName, endpoint: endpoint)
            } else {
                _ = store.addServer(name: resolvedName, endpoint: endpoint)
            }
            isSaving = false
            dismiss()
        }
    }
}
