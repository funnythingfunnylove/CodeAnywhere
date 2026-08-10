import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var showingNewProject = false
    @State private var searchText = ""
    @State private var selectedProject: ProjectSummary?

    private var activeProjects: [ProjectSummary] {
        store.projects.filter(matches)
    }

    private var pinnedProjects: [ProjectSummary] {
        activeProjects.filter(\.isPinned)
    }

    private var allProjects: [ProjectSummary] {
        activeProjects.filter { !$0.isPinned }
    }

    private var archivedProjects: [ProjectSummary] {
        store.archivedProjects.filter(matches)
    }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 0) {
                StableSearchField(text: $searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                if activeProjects.isEmpty && archivedProjects.isEmpty {
                EmptyStateView(icon: "folder.badge.plus", title: "还没有项目", message: "新建桌面端目录，或从新对话选择已有目录")
                } else {
                List {
                    if !pinnedProjects.isEmpty {
                        Section {
                            ForEach(pinnedProjects) { project in
                                ProjectRow(project: project, onOpen: { selectedProject = project })
                            }
                        } header: {
                            Label("已置顶", systemImage: "pin.fill")
                                .font(.headline)
                                .textCase(nil)
                        }
                    }
                    if !allProjects.isEmpty {
                        Section {
                            ForEach(allProjects) { project in
                                ProjectRow(project: project, onOpen: { selectedProject = project })
                            }
                        } header: {
                            Label("所有项目", systemImage: "folder")
                                .font(.headline)
                                .textCase(nil)
                        }
                    }
                    if !archivedProjects.isEmpty {
                        Section {
                            ForEach(archivedProjects) { project in
                                ProjectRow(project: project, onOpen: { selectedProject = project })
                            }
                        } header: {
                            Label("已归档项目", systemImage: "archivebox")
                                .font(.headline)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSeparator(.hidden)
                .listSectionSpacing(12)
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
        .navigationDestination(item: $selectedProject) { project in
            ProjectDetailView(project: project)
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView()
        }
    }

    private func matches(_ project: ProjectSummary) -> Bool {
        guard !searchText.isEmpty else { return true }
        return project.name.localizedCaseInsensitiveContains(searchText)
            || project.path.localizedCaseInsensitiveContains(searchText)
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var store: RemoteCodexStore
    let project: ProjectSummary
    let onOpen: () -> Void
    @State private var showingArchiveConfirmation = false

    var body: some View {
        Button {
            KeyboardDismiss.dismiss()
            onOpen()
        } label: {
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
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: 12)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden, edges: .all)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                KeyboardDismiss.dismiss()
                store.toggleProjectPin(project.path)
            } label: {
                Label(project.isPinned ? "取消固定" : "固定", systemImage: project.isPinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if project.isArchived {
                Button {
                    KeyboardDismiss.dismiss()
                    store.unarchiveProject(project.path)
                } label: {
                    Label("取消归档", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            } else {
                Button(role: .destructive) {
                    KeyboardDismiss.dismiss()
                    showingArchiveConfirmation = true
                } label: {
                    Label("归档", systemImage: "archivebox")
                }
            }
        }
        .alert("归档项目？", isPresented: $showingArchiveConfirmation) {
            Button("归档", role: .destructive) {
                store.archiveProject(project.path)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(project.name)”将从所有项目中移到已归档项目。")
        }
    }
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    let project: ProjectSummary
    @State private var showingNewConversation = false
    @State private var selectedThread: CodexThread?

    private var projectThreads: [CodexThread] { store.threads.filter { $0.cwd == project.path } }

    var body: some View {
        ZStack {
            AmbientBackground()
            if projectThreads.isEmpty {
                EmptyStateView(icon: "bubble.left", title: "项目已就绪", message: "为这个项目创建第一段对话")
            } else {
                List(projectThreads) { thread in
                    Button {
                        KeyboardDismiss.dismiss()
                        selectedThread = thread
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            HStack {
                                StatusPill(activity: thread.activity, compact: true)
                                Spacer()
                                Text(thread.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                    .listRowSeparator(.hidden, edges: .all)
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
        .navigationDestination(item: $selectedThread) { ChatView(thread: $0) }
        .sheet(isPresented: $showingNewConversation) {
            NewConversationView(initialPath: project.path) { thread in
                selectedThread = thread
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
