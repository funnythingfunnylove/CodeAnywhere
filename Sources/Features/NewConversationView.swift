import SwiftUI

struct NewConversationView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorageKey.defaultModel) private var defaultModelID = ""
    @AppStorage(StorageKey.defaultReasoningEffort) private var defaultReasoningEffort = ""
    var initialPath: String?
    var onCreated: ((CodexThread) -> Void)?

    @State private var path = ""
    @State private var prompt = ""
    @State private var selectedModelID = ""
    @State private var selectedEffort = ""
    @State private var isCreating = false
    @State private var didSetInitialPath = false
    @State private var didSetModelDefaults = false
    @FocusState private var promptFocused: Bool

    private var selectedModel: CodexModel? {
        store.models.first { $0.model == selectedModelID }
    }

    private var selectedReasoningLevel: OpenAIReasoningLevel {
        OpenAIReasoningLevel.resolve(selectedEffort) ?? .medium
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(spacing: DS.spacingMD) {
                        projectCard
                        modelCard
                        promptCard
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, DS.spacingXL)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("新对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "创建中…" : "开始") { create() }
                        .disabled(!canCreate || isCreating)
                        .accessibilityHint("使用当前项目、模型和思考级别创建对话")
                }
            }
            .onAppear { setInitialValuesIfNeeded() }
            .onChange(of: store.models) { _, _ in
                reconcileModelSelection()
            }
            .onChange(of: store.projects.map(\.path)) { _, _ in
                setInitialPathIfNeeded()
            }
            .interactiveDismissDisabled(isCreating)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var projectCard: some View {
        ConversationSetupCard(
            title: "项目目录",
            subtitle: "选择 Codex 要操作的桌面端工作区",
            systemImage: "folder.fill"
        ) {
            if !store.projects.isEmpty {
                Menu {
                    ForEach(store.projects) { project in
                        Button {
                            path = project.path
                        } label: {
                            if path == project.path {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                } label: {
                    ConversationSelectionRow(
                        title: "最近项目",
                        value: selectedProjectName,
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择最近项目")
                .accessibilityValue(selectedProjectName)

                Divider()
            }

            TextField("/Users/me/Projects/App", text: $path, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(minHeight: 48)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: DS.radiusSM, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DS.radiusSM, style: .continuous)
                        .strokeBorder(
                            pathIsInvalid ? Color.red.opacity(0.7) : Color(.separator).opacity(0.35),
                            lineWidth: 0.5
                        )
                }
                .accessibilityLabel("桌面端项目绝对路径")

            if pathIsInvalid {
                Label("请输入以 / 开头的绝对路径", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("路径属于运行 Codex 的 Mac，而不是这台 iPhone。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelCard: some View {
        ConversationSetupCard(
            title: "模型与思考",
            subtitle: "已带入“设置”中的默认值，本次可单独调整",
            systemImage: "cpu"
        ) {
            Menu {
                ForEach(store.models) { model in
                    Button {
                        select(model)
                    } label: {
                        if selectedModelID == model.model {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            } label: {
                ConversationSelectionRow(
                    title: "模型",
                    value: selectedModel?.displayName ?? "暂无可用模型",
                    systemImage: "cpu"
                )
            }
            .buttonStyle(.plain)
            .disabled(store.models.isEmpty)
            .accessibilityLabel("模型")
            .accessibilityValue(selectedModel?.displayName ?? "暂无可用模型")

            Divider()

            if selectedModel != nil {
                Menu {
                    Picker("思考级别", selection: $selectedEffort) {
                        ForEach(OpenAIReasoningLevel.allCases) { level in
                            Label(level.title, systemImage: level.systemImage)
                                .tag(level.rawValue)
                        }
                    }
                } label: {
                    ConversationSelectionRow(
                        title: "思考级别",
                        value: selectedReasoningLevel.title,
                        systemImage: selectedReasoningLevel.systemImage
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("思考级别")
                .accessibilityValue(selectedReasoningLevel.title)
            } else {
                ConversationSelectionRow(
                    title: "思考级别",
                    value: OpenAIReasoningLevel.medium.title,
                    systemImage: "brain.head.profile",
                    showsDisclosure: false
                )
                .foregroundStyle(.secondary)
            }

        }
    }

    private var promptCard: some View {
        ConversationSetupCard(
            title: "第一条消息",
            subtitle: "清楚说明目标、约束和希望得到的结果",
            systemImage: "text.bubble.fill"
        ) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("例如：检查登录流程，并修复进入首页时的闪退")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .focused($promptFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 170)
                    .accessibilityLabel("第一条消息")
            }
            .background(
                Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: DS.radiusSM, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusSM, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
        }
    }

    private var canCreate: Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedModelID.isEmpty
    }

    private var pathIsInvalid: Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/")
    }

    private var selectedProjectName: String {
        store.projects.first { $0.path == path }?.name ?? "选择项目"
    }

    private func setInitialValuesIfNeeded() {
        setInitialPathIfNeeded()
        reconcileModelSelection()
    }

    private func setInitialPathIfNeeded() {
        guard !didSetInitialPath else { return }
        if let initialPath {
            path = initialPath
            didSetInitialPath = true
            return
        }
        guard path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            didSetInitialPath = true
            return
        }
        guard let projectPath = store.projects.first?.path else { return }
        path = projectPath
        didSetInitialPath = true
    }

    private func reconcileModelSelection() {
        if !didSetModelDefaults {
            guard let selection = NewConversationDefaults.resolve(
                models: store.models,
                preferredModelID: defaultModelID,
                preferredReasoningEffort: defaultReasoningEffort
            ) else { return }
            selectedModelID = selection.modelID
            selectedEffort = selection.reasoningEffort ?? ""
            didSetModelDefaults = true
            return
        }

        guard let model = selectedModel else {
            didSetModelDefaults = false
            reconcileModelSelection()
            return
        }
        selectedEffort = OpenAIReasoningLevel.resolve(selectedEffort)?.rawValue
            ?? NewConversationDefaults.recommendedReasoningEffort(for: model)
            ?? OpenAIReasoningLevel.medium.rawValue
    }

    private func select(_ model: CodexModel) {
        selectedModelID = model.model
        selectedEffort = NewConversationDefaults.recommendedReasoningEffort(for: model) ?? ""
    }

    private func create() {
        isCreating = true
        Task {
            do {
                let id = try await store.createConversation(
                    path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                    prompt: prompt,
                    modelID: selectedModelID,
                    effort: selectedEffort.isEmpty ? nil : selectedEffort
                )
                await store.refreshThreads()
                if let thread = store.threads.first(where: { $0.id == id }) {
                    dismiss()
                    onCreated?(thread)
                } else {
                    dismiss()
                }
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}

private struct ConversationSetupCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(14)
        .contentCard(radius: DS.radiusMD)
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusMD, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }
}

private struct ConversationSelectionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String
    let systemImage: String
    var showsDisclosure = true

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        rowIcon
                        Text(title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        disclosureIcon
                    }
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 34)
                }
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 10) {
                    rowIcon
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    disclosureIcon
                }
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var rowIcon: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var disclosureIcon: some View {
        if showsDisclosure {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
