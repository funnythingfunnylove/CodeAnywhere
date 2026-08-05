import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var showingNewProject = false

    var body: some View {
        ZStack {
            AmbientBackground()
            if store.projects.isEmpty {
                EmptyStateView(icon: "folder.badge.plus", title: "还没有项目", message: "新建桌面端目录，或从新对话选择已有目录")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.spacingSM)], spacing: DS.spacingSM) {
                        ForEach(store.projects) { project in
                            ProjectRow(project: project)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewProject = true } label: {
                    Label("新建项目", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationDestination(for: ProjectSummary.self) { project in
            ProjectDetailView(project: project)
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView()
        }
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var store: RemoteCodexStore
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: project) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(project.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if project.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(project.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Label("\(project.threadCount) 个对话", systemImage: "bubble.left.and.bubble.right")
                            if let date = project.updatedAt {
                                Text("·")
                                Text(date, format: .relative(presentation: .named))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Button {
                store.toggleProjectPin(project.path)
            } label: {
                Image(systemName: project.isPinned ? "pin.slash" : "pin")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(project.isPinned ? Color.accentColor : Color.secondary)
            .accessibilityLabel(project.isPinned ? "取消置顶项目" : "置顶项目")
            .accessibilityHint(project.name)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentCard(radius: 12)
        .contentShape(Rectangle())
    }
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    let project: ProjectSummary
    @State private var showingNewConversation = false
    @State private var createdThread: CodexThread?

    private var projectThreads: [CodexThread] { store.threads.filter { $0.cwd == project.path } }

    var body: some View {
        ZStack {
            AmbientBackground()
            if projectThreads.isEmpty {
                EmptyStateView(icon: "bubble.left", title: "项目已就绪", message: "为这个项目创建第一段对话")
            } else {
                List(projectThreads) { thread in
                    NavigationLink(value: thread) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            HStack {
                                StatusPill(activity: thread.activity, compact: true)
                                Spacer()
                                Text(thread.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewConversation = true } label: { Label("新对话", systemImage: "square.and.pencil") }
            }
        }
        .navigationDestination(for: CodexThread.self) { ChatView(thread: $0) }
        .navigationDestination(item: $createdThread) { ChatView(thread: $0) }
        .sheet(isPresented: $showingNewConversation) {
            NewConversationView(initialPath: project.path) { thread in
                createdThread = thread
            }
        }
    }
}

private struct NewProjectView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("桌面端目录") {
                    TextField("/Users/me/Projects/MyApp", text: $path, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("将在运行 Codex 的电脑上递归创建目录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "创建中…" : "创建") { create() }
                        .disabled(!path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") || isCreating)
                }
            }
        }
    }

    private func create() {
        isCreating = true
        Task {
            do {
                try await store.createProject(path: path)
                dismiss()
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}
