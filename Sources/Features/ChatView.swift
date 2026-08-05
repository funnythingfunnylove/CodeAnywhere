import SwiftUI
import UIKit

enum ChatScrollTrigger: Equatable {
    case initialAppearance
    case messagesChanged
    case streamingChanged
    case composerFocusChanged(Bool)
    case keyboardFrameChanged
}

struct ChatScrollRequest: Equatable {
    let animated: Bool
    let waitsForKeyboard: Bool
}

enum ChatScrollPolicy {
    static func request(for trigger: ChatScrollTrigger) -> ChatScrollRequest? {
        switch trigger {
        case .initialAppearance:
            return ChatScrollRequest(animated: false, waitsForKeyboard: false)
        case .messagesChanged:
            return ChatScrollRequest(animated: true, waitsForKeyboard: false)
        case .streamingChanged:
            return ChatScrollRequest(animated: false, waitsForKeyboard: false)
        case .composerFocusChanged(true):
            return ChatScrollRequest(animated: true, waitsForKeyboard: true)
        case .composerFocusChanged(false):
            return nil
        case .keyboardFrameChanged:
            return ChatScrollRequest(animated: true, waitsForKeyboard: false)
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    let thread: CodexThread
    @State private var draft = ""
    @State private var selectedModelID: String?
    @State private var selectedEffort: String?
    @State private var isSending = false
    @FocusState private var composerFocused: Bool
    @AppStorage(StorageKey.defaultReasoningEffort) private var defaultReasoningEffort = OpenAIReasoningLevel.medium.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottomID = "conversation-bottom"

    private var detail: ThreadDetail? { store.threadDetails[thread.id] }
    private var currentThread: CodexThread { detail?.thread ?? thread }

    var body: some View {
        ZStack {
            AmbientBackground()
            messages
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .navigationTitle(currentThread.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(currentThread.title).font(.headline).lineLimit(1)
                    Text(currentThread.projectName).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if currentThread.activity == .active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { Task { await store.interrupt(threadID: thread.id) } } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("停止当前任务")
                }
            }
        }
        .task {
            if selectedEffort == nil {
                selectedEffort = OpenAIReasoningLevel.resolve(defaultReasoningEffort)?.rawValue
                    ?? OpenAIReasoningLevel.medium.rawValue
            }
            await store.loadThread(thread.id)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(detail?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    ForEach(store.streamingItems[thread.id] ?? []) { item in
                        if !item.displayedText.isEmpty {
                            MessageBubble(message: item.message, isStreaming: true)
                                .id(item.message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToBottom(using: proxy, trigger: .initialAppearance)
            }
            .onChange(of: detail?.messages.count ?? 0) { _, _ in
                scrollToBottom(using: proxy, trigger: .messagesChanged)
            }
            .onChange(of: store.streamingItems[thread.id]) { _, _ in
                scrollToBottom(using: proxy, trigger: .streamingChanged)
            }
            .onChange(of: composerFocused) { _, focused in
                scrollToBottom(using: proxy, trigger: .composerFocusChanged(focused))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                scrollToBottom(using: proxy, trigger: .keyboardFrameChanged)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                modelMenu
                reasoningMenu
                Spacer(minLength: 0)
                if currentThread.activity == .active {
                    Label("工作中", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize()
                }
            }

            HStack(alignment: .bottom, spacing: 7) {
                TextField("继续对话…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button { send() } label: {
                    Group {
                        if isSending { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up") }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .accessibilityLabel("发送")
            }
        }
        .padding(10)
        .glassSurface(radius: DS.radiusMD)
    }

    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: $selectedModelID) {
                Text("沿用当前模型").tag(String?.none)
                ForEach(store.models) { model in
                    Text(model.displayName).tag(model.model as String?)
                }
            }
        } label: {
            Label(modelSelectionLabel, systemImage: "cpu")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模型")
        .accessibilityValue(modelSelectionLabel)
        .accessibilityHint("选择下一条消息使用的模型")
        .onChange(of: selectedModelID) { _, _ in
            selectedEffort = OpenAIReasoningLevel.resolve(selectedEffort)?.rawValue
                ?? OpenAIReasoningLevel.medium.rawValue
        }
    }

    private var reasoningMenu: some View {
        Menu {
            Picker("思考级别", selection: $selectedEffort) {
                ForEach(OpenAIReasoningLevel.allCases) { level in
                    Label(level.title, systemImage: level.systemImage)
                        .tag(level.rawValue as String?)
                }
            }
        } label: {
            Label(reasoningSelectionLabel, systemImage: selectedReasoningLevel.systemImage)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("思考级别")
        .accessibilityValue(reasoningSelectionLabel)
        .accessibilityHint("选择下一条消息使用的思考级别")
    }

    private var selectedModel: CodexModel? {
        guard let selectedModelID else { return nil }
        return store.models.first { $0.model == selectedModelID }
    }

    private var modelSelectionLabel: String {
        selectedModel?.displayName ?? "当前模型"
    }

    private var reasoningSelectionLabel: String {
        selectedReasoningLevel.title
    }

    private var selectedReasoningLevel: OpenAIReasoningLevel {
        OpenAIReasoningLevel.resolve(selectedEffort) ?? .medium
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, trigger: ChatScrollTrigger) {
        guard let request = ChatScrollPolicy.request(for: trigger) else { return }
        Task { @MainActor in
            await Task.yield()
            if request.waitsForKeyboard {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if request.animated && !reduceMotion {
                withAnimation(.smooth) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private func send() {
        let prompt = draft
        draft = ""
        composerFocused = false
        isSending = true
        Task {
            do {
                try await store.send(prompt: prompt, threadID: thread.id, modelID: selectedModelID, effort: selectedEffort)
            } catch {
                store.errorMessage = error.localizedDescription
                draft = prompt
            }
            isSending = false
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    @State private var isExpanded: Bool

    init(message: ChatMessage, isStreaming: Bool = false) {
        self.message = message
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: !ChatMessageDisplayPolicy.startsCollapsed(message))
    }

    private var isUser: Bool { message.role == .user }
    private var isCollapsible: Bool { ChatMessageDisplayPolicy.startsCollapsed(message) }
    private var icon: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .reasoning: return "brain.head.profile"
        case .tool: return "terminal"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 34) }
            if !isUser {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(message.role == .error ? .red : Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
            }
            Group {
                if isCollapsible {
                    CollapsibleMessageContent(
                        message: message,
                        isStreaming: isStreaming,
                        isExpanded: $isExpanded
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        FormattedMessageContent(message: message, isUser: isUser)
                        if isStreaming { StreamingIndicator() }
                    }
                }
            }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            if !isUser { Spacer(minLength: 18) }
        }
        .frame(maxWidth: .infinity)
        .modifier(
            MessageAccessibilityModifier(
                keepsChildren: isCollapsible,
                label: accessibilityText
            )
        )
    }

    private var accessibilityText: String {
        let speaker = isUser ? "你" : "Codex"
        let imageText = message.images.map(\.altText).joined(separator: "，")
        let content = [message.text, imageText].filter { !$0.isEmpty }.joined(separator: "，")
        return "\(speaker)：\(content)"
    }
}

private struct CollapsibleMessageContent: View {
    let message: ChatMessage
    let isStreaming: Bool
    @Binding var isExpanded: Bool

    private var title: String {
        message.role == .reasoning ? "思考过程" : "命令行"
    }

    private var preview: String {
        message.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            FormattedMessageContent(message: message, isUser: false)
                .padding(.top, 7)
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !isExpanded, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("正在流式输出")
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .accessibilityHint(isExpanded ? "双击折叠" : "双击展开")
    }
}

private struct StreamingIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text("正在输出")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 正在流式输出")
    }
}

private struct MessageAccessibilityModifier: ViewModifier {
    let keepsChildren: Bool
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if keepsChildren {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
        }
    }
}

private struct FormattedMessageContent: View {
    let message: ChatMessage
    let isUser: Bool

    private var foreground: Color { isUser ? .white : .primary }
    private var secondaryForeground: Color { isUser ? .white.opacity(0.78) : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch message.format {
            case .markdown:
                let blocks = MessageBlockParser.parse(message.text)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            case .plain:
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                }
            case .code(let language):
                if !message.text.isEmpty {
                    CodeBlockView(language: language, text: message.text, isUser: isUser)
                }
            }

            ForEach(message.images) { image in
                ConversationImageView(image: image, isUser: isUser)
            }
        }
        .tint(isUser ? .white : .accentColor)
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.callout)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text, isUser: isUser)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(isUser ? Color.white.opacity(0.72) : Color.accentColor.opacity(0.72))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .foregroundStyle(secondaryForeground)
                    .textSelection(.enabled)
            }
        case .bulletedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                        Text(inlineMarkdown(item))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .foregroundStyle(foreground)
                }
            }
            .textSelection(.enabled)
        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .foregroundStyle(secondaryForeground)
                        Text(inlineMarkdown(item))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .foregroundStyle(foreground)
                }
            }
            .textSelection(.enabled)
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? (isUser ? .white : Color.green) : secondaryForeground)
                        Text(inlineMarkdown(item.text))
                            .strikethrough(item.isCompleted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .foregroundStyle(foreground)
                }
            }
            .textSelection(.enabled)
        case .table(let headers, let rows):
            MessageTableView(headers: headers, rows: rows, isUser: isUser)
        case .image(let image):
            ConversationImageView(image: image, isUser: isUser)
        case .divider:
            Divider().overlay(isUser ? Color.white.opacity(0.5) : Color.secondary.opacity(0.4))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline.weight(.bold)
        default: return .subheadline.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let text: String
    let isUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isUser ? .white.opacity(0.72) : .secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isUser ? .white : .primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(
            isUser ? Color.black.opacity(0.20) : Color(.tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel([language.map { "\($0) 代码" }, text].compactMap { $0 }.joined(separator: "，"))
    }
}

private struct MessageTableView: View {
    let headers: [String]
    let rows: [[String]]
    let isUser: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    tableRow(normalized(row), isHeader: false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isUser ? Color.white.opacity(0.28) : Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
        }
        .accessibilityLabel("表格，共 \(headers.count) 列、\(rows.count) 行")
    }

    private func normalized(_ row: [String]) -> [String] {
        if row.count >= headers.count { return Array(row.prefix(headers.count)) }
        return row + Array(repeating: "", count: headers.count - row.count)
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(inlineMarkdown(cell))
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .foregroundStyle(isUser ? .white : .primary)
                    .frame(minWidth: 76, maxWidth: 190, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(isHeader ? headerBackground : Color.clear)
            }
        }
    }

    private var headerBackground: Color {
        isUser ? Color.black.opacity(0.16) : Color(.tertiarySystemBackground)
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

private struct ConversationImageView: View {
    private enum LocalImageState {
        case loading
        case loaded(UIImage)
        case failed(String)
    }

    @EnvironmentObject private var store: RemoteCodexStore
    let image: ChatImage
    let isUser: Bool
    @State private var localState: LocalImageState = .loading

    var body: some View {
        Group {
            switch image.source {
            case .remoteURL(let value):
                if let url = ChatImagePolicy.remoteURL(from: value) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            imagePlaceholder { ProgressView().tint(isUser ? .white : .accentColor) }
                        case .success(let loadedImage):
                            rendered(loadedImage)
                        case .failure:
                            imageFailure("图片下载失败")
                        @unknown default:
                            imageFailure("无法显示图片")
                        }
                    }
                } else {
                    imageFailure("图片地址无效")
                }
            case .dataURL:
                switch localState {
                case .loading:
                    imagePlaceholder { ProgressView().tint(isUser ? .white : .accentColor) }
                case .loaded(let uiImage):
                    rendered(Image(uiImage: uiImage))
                case .failed(let message):
                    imageFailure(message)
                }
            case .localPath(let path):
                switch localState {
                case .loading:
                    imagePlaceholder { ProgressView().tint(isUser ? .white : .accentColor) }
                case .loaded(let uiImage):
                    rendered(Image(uiImage: uiImage))
                case .failed(let message):
                    imageFailure(message) {
                        Task { await loadRemoteImage(path: path) }
                    }
                }
            }
        }
        .task(id: image.source) {
            switch image.source {
            case .localPath(let path):
                await loadRemoteImage(path: path)
            case .dataURL(let value):
                await loadEmbeddedImage(value)
            case .remoteURL:
                break
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image.altText)
    }

    private func rendered(_ loadedImage: Image) -> some View {
        loadedImage
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 320)
            .background(Color.black.opacity(isUser ? 0.10 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func imagePlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                isUser ? Color.black.opacity(0.12) : Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private func imageFailure(_ message: String, retry: (() -> Void)? = nil) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title3)
            Text(message).font(.caption)
            if let retry {
                Button("重试", action: retry)
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(isUser ? .white.opacity(0.85) : .secondary)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            isUser ? Color.black.opacity(0.12) : Color(.tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @MainActor
    private func loadRemoteImage(path: String) async {
        localState = .loading
        do {
            let data = try await store.imageData(atRemotePath: path)
            guard let uiImage = UIImage(data: data) else {
                localState = .failed("文件不是可识别的图片")
                return
            }
            localState = .loaded(uiImage)
        } catch {
            localState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadEmbeddedImage(_ value: String) async {
        localState = .loading
        let data = await Task.detached(priority: .userInitiated) {
            Self.data(fromDataURL: value)
        }.value
        guard let data, let uiImage = UIImage(data: data) else {
            localState = .failed("图片数据无效或过大")
            return
        }
        localState = .loaded(uiImage)
    }

    nonisolated private static func data(fromDataURL value: String) -> Data? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let metadata = value[..<comma].lowercased()
        guard metadata.hasPrefix("data:image/"), metadata.contains(";base64") else { return nil }
        let encoded = String(value[value.index(after: comma)...])
        guard encoded.utf8.count <= ChatImagePolicy.maximumEncodedDataURLBytes,
              let data = Data(base64Encoded: encoded),
              data.count <= ChatImagePolicy.maximumDecodedImageBytes else { return nil }
        return data
    }
}
