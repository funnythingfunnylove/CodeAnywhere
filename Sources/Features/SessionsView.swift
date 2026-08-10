import SwiftUI
import UIKit

struct SessionsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var searchText = ""
    @State private var showingNewConversation = false
    @State private var selectedThread: CodexThread?

    private var activeThreads: [CodexThread] {
        store.threads.filter { !$0.isArchived && matches($0) }
    }

    private var pinnedThreads: [CodexThread] {
        activeThreads.filter(\.isPinned)
    }

    private var allThreads: [CodexThread] {
        activeThreads.filter { !$0.isPinned }
    }

    private var archivedThreads: [CodexThread] {
        store.threads.filter { $0.isArchived && matches($0) }
    }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 0) {
                StableSearchField(text: $searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                if store.threads.isEmpty {
                    EmptyStateView(icon: "bubble.left.and.exclamationmark.bubble.right", title: "还没有对话", message: "从右上角新建一段 Codex 对话")
                } else if pinnedThreads.isEmpty && allThreads.isEmpty && archivedThreads.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的对话", message: "换个关键词搜索对话标题或项目")
                } else {
                    List {
                        if !pinnedThreads.isEmpty {
                            Section {
                                ForEach(pinnedThreads) { sessionRow($0) }
                            } header: {
                                SessionSectionHeader(title: "已置顶", systemImage: "pin.fill")
                            }
                        }
                        if !allThreads.isEmpty {
                            Section {
                                ForEach(allThreads) { sessionRow($0) }
                            } header: {
                                SessionSectionHeader(title: "所有对话", systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                        if !archivedThreads.isEmpty {
                            Section {
                                ForEach(archivedThreads) { sessionRow($0) }
                            } header: {
                                SessionSectionHeader(title: "已归档", systemImage: "archivebox")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .listRowSeparator(.hidden)
                    .listSectionSpacing(12)
                    .refreshable { await store.refreshThreads() }
                }
            }
        }
        .navigationTitle("所有对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewConversation = true } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .accessibilityHint("选择项目、模型与思考级别")
            }
        }
        .navigationDestination(item: $selectedThread) { thread in
            ChatView(thread: thread)
        }
        .sheet(isPresented: $showingNewConversation) {
            NewConversationView { thread in
                selectedThread = thread
            }
        }
        .onAppear { openRequestedThreadIfAvailable() }
        .onChange(of: store.requestedThreadID) { _, _ in openRequestedThreadIfAvailable() }
        .onChange(of: store.threads.map(\.id)) { _, _ in openRequestedThreadIfAvailable() }
    }

    @ViewBuilder
    private func sessionRow(_ thread: CodexThread) -> some View {
        SessionRow(
            thread: thread,
            onOpen: { selectedThread = thread },
            onPin: { store.toggleThreadPin(thread.id) },
            onArchive: {
                Task {
                    if thread.isArchived {
                        await store.unarchiveThread(thread.id)
                    } else {
                        await store.archiveThread(thread.id)
                    }
                }
            }
        )
    }

    private func matches(_ thread: CodexThread) -> Bool {
        guard !searchText.isEmpty else { return true }
        return thread.title.localizedCaseInsensitiveContains(searchText)
            || thread.cwd.localizedCaseInsensitiveContains(searchText)
    }

    private func openRequestedThreadIfAvailable() {
        guard let threadID = store.requestedThreadID,
              let thread = store.threads.first(where: { $0.id == threadID }) else { return }
        selectedThread = thread
        store.consumeRequestedThread()
    }
}

private struct SessionSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .textCase(nil)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
    }
}

struct StableSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索对话或项目", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button("清除", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 2)
        .frame(minHeight: 44)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SessionRow: View {
    let thread: CodexThread
    let onOpen: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    @State private var showingArchiveConfirmation = false

    var body: some View {
        Button {
            KeyboardDismiss.dismiss()
            onOpen()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: thread.activity == .active ? "sparkles" : "bubble.left.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(thread.activity == .active ? .orange : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Label(thread.projectName, systemImage: "folder")
                            .lineLimit(1)
                        Text("·")
                        Text(thread.updatedAt, format: .relative(presentation: .named))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                StatusPill(activity: thread.activity, compact: true)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden, edges: .all)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                KeyboardDismiss.dismiss()
                onPin()
            } label: {
                Label(thread.isPinned ? "取消固定" : "固定", systemImage: thread.isPinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if thread.isArchived {
                Button {
                    KeyboardDismiss.dismiss()
                    onArchive()
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
        .alert("归档对话？", isPresented: $showingArchiveConfirmation) {
            Button("归档", role: .destructive, action: onArchive)
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(thread.title)”将从所有对话中移到已归档。")
        }
    }
}

enum KeyboardDismiss {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
