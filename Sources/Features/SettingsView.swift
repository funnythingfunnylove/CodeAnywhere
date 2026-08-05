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
                Section("连接") {
                    LabeledContent("IP 地址", value: store.endpoint.host)
                    LabeledContent("端口", value: String(store.endpoint.port))
                    if case .connected(let server) = store.connectionState {
                        LabeledContent("服务端", value: server)
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
