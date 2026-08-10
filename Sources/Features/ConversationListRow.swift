import SwiftUI

struct ConversationListRow: View {
    let thread: CodexThread
    let showsProject: Bool
    let onOpen: () -> Void
    let onPin: (() -> Void)?
    let onArchive: (() -> Void)?
    @State private var showingArchiveConfirmation = false

    init(
        thread: CodexThread,
        showsProject: Bool = true,
        onOpen: @escaping () -> Void,
        onPin: (() -> Void)? = nil,
        onArchive: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.showsProject = showsProject
        self.onOpen = onOpen
        self.onPin = onPin
        self.onArchive = onArchive
    }

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
                    .background(
                        Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if showsProject {
                            Label(thread.projectName, systemImage: "folder")
                                .lineLimit(1)
                            Text("·")
                        }
                        Text(thread.updatedAt, format: .relative(presentation: .named))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                StatusPill(activity: thread.activity, compact: true)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden, edges: .all)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onPin {
                Button {
                    KeyboardDismiss.dismiss()
                    onPin()
                } label: {
                    Label(thread.isPinned ? "取消固定" : "固定", systemImage: thread.isPinned ? "pin.slash" : "pin")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onArchive {
                Button {
                    KeyboardDismiss.dismiss()
                    if thread.isArchived {
                        onArchive()
                    } else {
                        showingArchiveConfirmation = true
                    }
                } label: {
                    Label(
                        thread.isArchived ? "取消归档" : "归档",
                        systemImage: thread.isArchived ? "arrow.uturn.backward" : "archivebox"
                    )
                }
                .tint(thread.isArchived ? .orange : .red)
            }
        }
        .alert("归档对话？", isPresented: $showingArchiveConfirmation) {
            Button("归档", role: .destructive) { onArchive?() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("“\(thread.title)”将从所有对话中移到已归档。")
        }
    }
}
