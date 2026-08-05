import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var searchText = ""
    @State private var showingNewConversation = false
    @State private var createdThread: CodexThread?

    private var filteredThreads: [CodexThread] {
        guard !searchText.isEmpty else { return store.threads }
        return store.threads.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.cwd.localizedCaseInsensitiveContains(searchText)
        }
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
                } else if filteredThreads.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的对话", message: "换个关键词搜索对话标题或项目")
                } else {
                    ScrollView {
                        LazyVStack(spacing: DS.spacingSM) {
                            ForEach(filteredThreads) { thread in
                                NavigationLink(value: thread) {
                                    SessionRow(thread: thread)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
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
        .navigationDestination(for: CodexThread.self) { thread in
            ChatView(thread: thread)
        }
        .navigationDestination(item: $createdThread) { thread in
            ChatView(thread: thread)
        }
        .sheet(isPresented: $showingNewConversation) {
            NewConversationView { thread in
                createdThread = thread
            }
        }
        .onAppear { openRequestedThreadIfAvailable() }
        .onChange(of: store.requestedThreadID) { _, _ in openRequestedThreadIfAvailable() }
        .onChange(of: store.threads.map(\.id)) { _, _ in openRequestedThreadIfAvailable() }
    }

    private func openRequestedThreadIfAvailable() {
        guard let threadID = store.requestedThreadID,
              let thread = store.threads.first(where: { $0.id == threadID }) else { return }
        createdThread = thread
        store.consumeRequestedThread()
    }
}

private struct StableSearchField: View {
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

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: thread.activity == .active ? "sparkles" : "bubble.left.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(thread.activity == .active ? .orange : Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
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
            VStack(alignment: .trailing, spacing: 5) {
                StatusPill(activity: thread.activity, compact: true)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentCard(radius: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.title)，\(thread.projectName)，\(thread.activity.title)")
    }
}
