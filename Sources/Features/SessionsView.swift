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
        ConversationListRow(
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

enum KeyboardDismiss {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
