import SwiftUI

struct NewConversationView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss
    var initialPath: String?
    var onCreated: ((CodexThread) -> Void)?

    @State private var path = ""
    @State private var prompt = ""
    @State private var selectedModelID = ""
    @State private var selectedEffort = ""
    @State private var isCreating = false

    private var selectedModel: CodexModel? {
        store.models.first { $0.model == selectedModelID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    if !store.projects.isEmpty {
                        Picker("工作目录", selection: $path) {
                            ForEach(store.projects) { project in
                                Text(project.name).tag(project.path)
                            }
                        }
                    }
                    TextField("桌面端绝对路径，例如 /Users/me/Projects/App", text: $path, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section("模型与思考") {
                    Picker("模型", selection: $selectedModelID) {
                        ForEach(store.models) { model in
                            Text(model.displayName).tag(model.model)
                        }
                    }
                    .onChange(of: selectedModelID) { _, newValue in
                        if let model = store.models.first(where: { $0.model == newValue }) {
                            selectedEffort = model.defaultReasoningEffort
                        }
                    }

                    Picker("思考级别", selection: $selectedEffort) {
                        ForEach(selectedModel?.reasoningOptions ?? []) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }

                    if let option = selectedModel?.reasoningOptions.first(where: { $0.id == selectedEffort }), !option.description.isEmpty {
                        Text(option.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("第一条消息") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                        .accessibilityLabel("第一条消息")
                }
            }
            .navigationTitle("新对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "创建中…" : "创建") { create() }
                        .disabled(!canCreate || isCreating)
                }
            }
            .onAppear { setDefaults() }
        }
        .presentationDetents([.large])
    }

    private var canCreate: Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedModelID.isEmpty
    }

    private func setDefaults() {
        path = initialPath ?? store.projects.first?.path ?? ""
        let model = store.models.first(where: \.isDefault) ?? store.models.first
        selectedModelID = model?.model ?? ""
        selectedEffort = model?.defaultReasoningEffort ?? "medium"
    }

    private func create() {
        isCreating = true
        Task {
            do {
                let id = try await store.createConversation(
                    path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                    prompt: prompt,
                    modelID: selectedModelID,
                    effort: selectedEffort
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

