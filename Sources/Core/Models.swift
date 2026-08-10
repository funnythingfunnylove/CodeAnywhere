import Foundation

struct ServerEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: Int

    static let fallback = ServerEndpoint(host: "192.168.1.10", port: 4500)
    static let internalCapabilityToken = "codeanywhere-lan-v1"

    var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = port
        components.path = "/"
        return components.url
    }

    var isValid: Bool {
        webSocketURL != nil && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(port)
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(server: String)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct ReasoningOption: Identifiable, Hashable, Sendable {
    let id: String
    let description: String

    var displayName: String {
        switch id.lowercased() {
        case "none": return "关闭"
        case "minimal": return "最少"
        case "low": return "较少"
        case "medium": return "标准"
        case "high": return "深入"
        case "max", "xhigh": return "极致"
        default: return id
        }
    }
}

enum OpenAIReasoningLevel: String, CaseIterable, Identifiable, Sendable {
    case light = "low"
    case medium
    case high
    case extraHigh = "xhigh"
    case max
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        case .extraHigh: return "Extra High"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "leaf"
        case .medium: return "circle.lefthalf.filled"
        case .high: return "brain.head.profile"
        case .extraHigh: return "bolt"
        case .max: return "flame"
        case .ultra: return "sparkles"
        }
    }

    static func resolve(_ value: String?) -> OpenAIReasoningLevel? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "light", "low": return .light
        case "medium": return .medium
        case "high": return .high
        case "extra high", "extra_high", "extrahigh", "xhigh": return .extraHigh
        case "max": return .max
        case "ultra": return .ultra
        default: return nil
        }
    }
}

struct CodexModel: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let reasoningOptions: [ReasoningOption]

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let model = json["model"]?.stringValue,
              let displayName = json["displayName"]?.stringValue else { return nil }
        self.id = id
        self.model = model
        self.displayName = displayName
        description = json["description"]?.stringValue ?? ""
        isDefault = json["isDefault"]?.boolValue ?? false
        defaultReasoningEffort = json["defaultReasoningEffort"]?.stringValue ?? "medium"
        reasoningOptions = (json["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { value in
            guard let effort = value["reasoningEffort"]?.stringValue else { return nil }
            return ReasoningOption(id: effort, description: value["description"]?.stringValue ?? "")
        }
    }
}

struct NewConversationDefaults: Equatable, Sendable {
    let modelID: String
    let reasoningEffort: String?

    static func resolve(
        models: [CodexModel],
        preferredModelID: String?,
        preferredReasoningEffort: String?
    ) -> NewConversationDefaults? {
        guard let model = preferredModel(in: models, preferredModelID: preferredModelID) else {
            return nil
        }

        let preferredEffort = OpenAIReasoningLevel.resolve(preferredReasoningEffort)?.rawValue
        return NewConversationDefaults(
            modelID: model.model,
            reasoningEffort: preferredEffort ?? recommendedReasoningEffort(for: model)
        )
    }

    static func preferredModel(
        in models: [CodexModel],
        preferredModelID: String?
    ) -> CodexModel? {
        let preferredID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return models.first { $0.model == preferredID }
            ?? models.first(where: \.isDefault)
            ?? models.first
    }

    static func recommendedReasoningEffort(for model: CodexModel) -> String? {
        OpenAIReasoningLevel.resolve(model.defaultReasoningEffort)?.rawValue
            ?? OpenAIReasoningLevel.medium.rawValue
    }
}

enum ThreadActivity: String, Codable, Sendable {
    case active
    case idle
    case notLoaded
    case systemError
    case unknown

    var title: String {
        switch self {
        case .active: return "运行中"
        case .idle: return "已完成"
        case .notLoaded: return "未载入"
        case .systemError: return "出错"
        case .unknown: return "未知"
        }
    }
}

struct CodexThread: Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    var preview: String
    var cwd: String
    var createdAt: Date
    var updatedAt: Date
    var activity: ThreadActivity
    var isPinned: Bool
    var isArchived: Bool

    var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let previewText = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return previewText.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : previewText
    }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let cwd = json["cwd"]?.stringValue else { return nil }
        self.id = id
        self.cwd = cwd
        name = json["name"]?.stringValue
        preview = json["preview"]?.stringValue ?? ""
        createdAt = Self.date(from: json["createdAt"]?.intValue)
        updatedAt = Self.date(from: json["updatedAt"]?.intValue)
        isPinned = json["isPinned"]?.boolValue ?? false
        isArchived = json["archived"]?.boolValue ?? false
        let status = json["status"]?["type"]?.stringValue ?? json["status"]?.stringValue ?? "unknown"
        activity = ThreadActivity(rawValue: status) ?? .unknown
    }

    private static func date(from rawValue: Int?) -> Date {
        guard let rawValue else { return .distantPast }
        let seconds = rawValue > 10_000_000_000 ? Double(rawValue) / 1_000 : Double(rawValue)
        return Date(timeIntervalSince1970: seconds)
    }
}

enum MessageRole: String, Sendable {
    case user
    case assistant
    case reasoning
    case tool
    case error
}

enum ChatMessageFormat: Hashable, Sendable {
    case markdown
    case plain
    case code(language: String?)
}

enum ChatImageSource: Hashable, Sendable {
    case remoteURL(String)
    case localPath(String)
    case dataURL(String)
}

struct ChatImage: Identifiable, Hashable, Sendable {
    let id: String
    let source: ChatImageSource
    let altText: String
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let role: MessageRole
    let text: String
    let date: Date?
    let format: ChatMessageFormat
    let images: [ChatImage]

    init(
        id: String,
        role: MessageRole,
        text: String,
        date: Date?,
        format: ChatMessageFormat = .markdown,
        images: [ChatImage] = []
    ) {
        self.id = id
        self.role = role
        self.text = ChatTextSanitizer.clean(text)
        self.date = date
        self.format = format
        self.images = images
    }
}

enum StreamingChatItemKind: Hashable, Sendable {
    case assistant
    case reasoning
    case command
}

enum StreamingChatItemChannel: Sendable {
    case primary
    case secondary
}

struct StreamingChatItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: StreamingChatItemKind
    var primaryText: String
    var secondaryText: String

    init(
        id: String,
        kind: StreamingChatItemKind,
        primaryText: String = "",
        secondaryText: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }

    var displayedText: String {
        switch kind {
        case .assistant:
            return primaryText
        case .reasoning:
            return primaryText.isEmpty ? secondaryText : primaryText
        case .command:
            return [primaryText, secondaryText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    var message: ChatMessage {
        switch kind {
        case .assistant:
            return ChatMessage(id: "stream-\(id)", role: .assistant, text: displayedText, date: nil)
        case .reasoning:
            return ChatMessage(id: "stream-\(id)", role: .reasoning, text: displayedText, date: nil)
        case .command:
            return ChatMessage(
                id: "stream-\(id)",
                role: .tool,
                text: displayedText,
                date: nil,
                format: .code(language: "shell")
            )
        }
    }

    mutating func append(_ delta: String, to channel: StreamingChatItemChannel) {
        switch channel {
        case .primary: primaryText += delta
        case .secondary: secondaryText += delta
        }
    }
}

enum ChatMessageDisplayPolicy {
    static func startsCollapsed(_ message: ChatMessage) -> Bool {
        if message.role == .reasoning { return true }
        guard message.role == .tool,
              case .code(let language) = message.format else { return false }
        return language?.lowercased() == "shell"
    }
}

struct ThreadDetail: Sendable {
    var thread: CodexThread
    var messages: [ChatMessage]
    var latestTurnID: String?

    init?(json: JSONValue) {
        guard let thread = CodexThread(json: json) else { return nil }
        self.thread = thread
        var parsedMessages: [ChatMessage] = []
        var lastTurnID: String?

        for turn in json["turns"]?.arrayValue ?? [] {
            lastTurnID = turn["id"]?.stringValue ?? lastTurnID
            let timestamp = Self.date(from: turn["startedAt"]?.intValue)
            for item in turn["items"]?.arrayValue ?? [] {
                guard let message = Self.message(from: item, date: timestamp) else { continue }
                parsedMessages.append(message)
            }
            if let error = turn["error"]?["message"]?.stringValue, !error.isEmpty {
                parsedMessages.append(ChatMessage(id: "error-\(lastTurnID ?? UUID().uuidString)", role: .error, text: error, date: timestamp))
            }
        }
        messages = parsedMessages
        latestTurnID = lastTurnID
    }

    private static func message(from item: JSONValue, date: Date?) -> ChatMessage? {
        guard let type = item["type"]?.stringValue else { return nil }
        let id = item["id"]?.stringValue ?? UUID().uuidString
        switch type {
        case "userMessage":
            var textParts: [String] = []
            var images: [ChatImage] = []
            let contentValues = item["content"]?.arrayValue ?? item["content"].map { [$0] } ?? []
            for (index, content) in contentValues.enumerated() {
                if let text = content.stringValue, !text.isEmpty {
                    textParts.append(text)
                    continue
                }
                let contentType = content["type"]?.stringValue ?? ""
                switch contentType {
                case "text":
                    if let text = content["text"]?.stringValue, !text.isEmpty { textParts.append(text) }
                case "image":
                    if let url = content["url"]?.stringValue,
                       let image = image(id: "\(id)-image-\(index)", value: url, altText: "用户图片", allowLocalPath: false) {
                        images.append(image)
                    }
                case "localImage":
                    if let path = content["path"]?.stringValue,
                       let image = image(
                        id: "\(id)-image-\(index)",
                        value: path,
                        altText: URL(fileURLWithPath: path).lastPathComponent,
                        allowLocalPath: true
                       ) {
                        images.append(image)
                    }
                case "audio", "localAudio":
                    let location = content["url"]?.stringValue ?? content["path"]?.stringValue ?? ""
                    textParts.append(location.isEmpty ? "音频附件" : "音频附件：\(location)")
                case "skill":
                    if let name = content["name"]?.stringValue { textParts.append("技能：\(name)") }
                case "mention":
                    if let name = content["name"]?.stringValue { textParts.append("@\(name)") }
                default:
                    if let text = content["text"]?.stringValue, !text.isEmpty { textParts.append(text) }
                }
            }
            let text = textParts.joined(separator: "\n")
            return text.isEmpty && images.isEmpty ? nil : ChatMessage(id: id, role: .user, text: text, date: date, images: images)
        case "agentMessage":
            guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            return ChatMessage(id: id, role: .assistant, text: text, date: date)
        case "hookPrompt":
            let text = textFragments(from: item["fragments"]).joined(separator: "\n")
            return text.isEmpty ? nil : ChatMessage(id: id, role: .reasoning, text: text, date: date, format: .plain)
        case "reasoning":
            let summary = textFragments(from: item["summary"])
            let content = textFragments(from: item["content"])
            let text = (summary.isEmpty ? content : summary).joined(separator: "\n")
            return text.isEmpty ? nil : ChatMessage(id: id, role: .reasoning, text: text, date: date)
        case "plan":
            guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            return ChatMessage(id: id, role: .reasoning, text: text, date: date)
        case "commandExecution":
            let command = item["command"]?.stringValue ?? "命令"
            let output = item["aggregatedOutput"]?.stringValue ?? ""
            let status = item["status"]?.stringValue
            let exitCode = item["exitCode"]?.intValue
            var lines = [command]
            if !output.isEmpty { lines.append(output) }
            if let status, status == "failed" { lines.append("状态：失败") }
            if let exitCode { lines.append("退出码：\(exitCode)") }
            return ChatMessage(id: id, role: .tool, text: lines.joined(separator: "\n"), date: date, format: .code(language: "shell"))
        case "fileChange":
            let changes = item["changes"]?.arrayValue ?? []
            let details = changes.compactMap { change -> String? in
                guard let path = change["path"]?.stringValue else { return nil }
                let kind = change["kind"]?["type"]?.stringValue ?? "update"
                let label: String
                switch kind {
                case "add": label = "新增"
                case "delete": label = "删除"
                case "update": label = "修改"
                default: label = kind
                }
                return "- \(label) `\(path)`"
            }
            let header = "已更新 \(changes.count) 个文件"
            return ChatMessage(id: id, role: .tool, text: ([header] + details).joined(separator: "\n"), date: date)
        case "mcpToolCall":
            let server = item["server"]?.stringValue
            let tool = item["tool"]?.stringValue ?? "工具调用"
            let title = [server, tool].compactMap { $0 }.joined(separator: " / ")
            var textParts = [title.isEmpty ? "工具调用" : title]
            var images: [ChatImage] = []
            for (index, content) in (item["result"]?["content"]?.arrayValue ?? []).enumerated() {
                switch content["type"]?.stringValue {
                case "text":
                    if let text = content["text"]?.stringValue, !text.isEmpty { textParts.append(text) }
                case "image":
                    if let data = content["data"]?.stringValue, !data.isEmpty {
                        let mimeType = content["mimeType"]?.stringValue ?? "image/png"
                        let value = "data:\(mimeType);base64,\(data)"
                        if let image = image(id: "\(id)-image-\(index)", value: value, altText: "工具返回的图片", allowLocalPath: false) {
                            images.append(image)
                        }
                    } else if let value = content["url"]?.stringValue ?? content["imageUrl"]?.stringValue,
                              let image = image(id: "\(id)-image-\(index)", value: value, altText: "工具返回的图片", allowLocalPath: false) {
                        images.append(image)
                    }
                case "resource_link":
                    if let uri = content["uri"]?.stringValue { textParts.append(uri) }
                case "resource":
                    if let resource = content["resource"],
                       let blob = resource["blob"]?.stringValue,
                       let mimeType = resource["mimeType"]?.stringValue,
                       let image = image(
                        id: "\(id)-image-\(index)",
                        value: "data:\(mimeType);base64,\(blob)",
                        altText: "工具返回的图片",
                        allowLocalPath: false
                       ) {
                        images.append(image)
                    } else if let uri = content["resource"]?["uri"]?.stringValue {
                        textParts.append(uri)
                    }
                case "audio":
                    textParts.append("工具返回了音频附件")
                default:
                    if let text = content["text"]?.stringValue, !text.isEmpty { textParts.append(text) }
                }
            }
            if let resultText = item["result"]?["content"]?.stringValue, !resultText.isEmpty {
                textParts.append(resultText)
            }
            if let error = item["error"]?["message"]?.stringValue, !error.isEmpty { textParts.append("错误：\(error)") }
            return ChatMessage(id: id, role: .tool, text: textParts.joined(separator: "\n"), date: date, images: images)
        case "dynamicToolCall":
            let tool = item["tool"]?.stringValue ?? "工具调用"
            var textParts = [tool]
            var images: [ChatImage] = []
            for (index, content) in (item["contentItems"]?.arrayValue ?? []).enumerated() {
                switch content["type"]?.stringValue {
                case "inputText":
                    if let text = content["text"]?.stringValue, !text.isEmpty { textParts.append(text) }
                case "inputImage":
                    if let value = content["imageUrl"]?.stringValue,
                       let image = image(id: "\(id)-image-\(index)", value: value, altText: "工具返回的图片", allowLocalPath: false) {
                        images.append(image)
                    }
                case "inputAudio":
                    if let value = content["audioUrl"]?.stringValue { textParts.append("音频结果：\(value)") }
                default:
                    break
                }
            }
            return ChatMessage(id: id, role: .tool, text: textParts.joined(separator: "\n"), date: date, images: images)
        case "collabAgentToolCall", "collabToolCall":
            let tool = item["tool"]?.stringValue ?? "协作代理"
            let status = item["status"]?.stringValue ?? ""
            let prompt = item["prompt"]?.stringValue
            let receiverCount = item["receiverThreadIds"]?.arrayValue?.count ?? 0
            let target = receiverCount > 0 ? "目标代理：\(receiverCount)" : nil
            return ChatMessage(
                id: id,
                role: .tool,
                text: ["协作：\(tool) \(status)", target, prompt].compactMap { $0 }.joined(separator: "\n"),
                date: date
            )
        case "subAgentActivity":
            let kind = item["kind"]?.stringValue ?? "更新"
            let path = item["agentPath"]?.stringValue ?? "子代理"
            return ChatMessage(id: id, role: .tool, text: "\(path)：\(kind)", date: date, format: .plain)
        case "webSearch":
            let query = item["query"]?.stringValue ?? ""
            return ChatMessage(id: id, role: .tool, text: query.isEmpty ? "网页搜索" : "网页搜索：\(query)", date: date, format: .plain)
        case "imageView":
            guard let path = item["path"]?.stringValue, !path.isEmpty else { return nil }
            guard let image = image(
                id: "\(id)-image",
                value: path,
                altText: URL(fileURLWithPath: path).lastPathComponent,
                allowLocalPath: true
            ) else { return nil }
            return ChatMessage(id: id, role: .tool, text: "查看图片", date: date, format: .plain, images: [image])
        case "sleep":
            let duration = item["durationMs"]?.intValue ?? 0
            let seconds = Double(duration) / 1_000
            let text = seconds >= 1 ? "等待 \(seconds.formatted(.number.precision(.fractionLength(0...1)))) 秒" : "短暂等待"
            return ChatMessage(id: id, role: .tool, text: text, date: date, format: .plain)
        case "imageGeneration":
            let result = item["result"]?.stringValue ?? "图片生成"
            var images: [ChatImage] = []
            if let path = item["savedPath"]?.stringValue, !path.isEmpty {
                if let image = image(
                    id: "\(id)-image",
                    value: path,
                    altText: URL(fileURLWithPath: path).lastPathComponent,
                    allowLocalPath: true
                ) {
                    images.append(image)
                }
            } else if let image = image(id: "\(id)-image", value: result, altText: "生成的图片", allowLocalPath: false) {
                images.append(image)
            }
            let resultIsImageReference = image(id: "probe", value: result, altText: "", allowLocalPath: false) != nil
            let text = resultIsImageReference ? "生成的图片" : result
            return ChatMessage(id: id, role: .tool, text: text, date: date, images: images)
        case "enteredReviewMode":
            let review = item["review"]?.stringValue ?? ""
            return ChatMessage(id: id, role: .reasoning, text: "进入代码审查\n\(review)", date: date)
        case "exitedReviewMode":
            let review = item["review"]?.stringValue ?? ""
            return ChatMessage(id: id, role: .reasoning, text: "完成代码审查\n\(review)", date: date)
        case "contextCompaction":
            return ChatMessage(id: id, role: .reasoning, text: "上下文已压缩", date: date, format: .plain)
        default:
            let fallback = ["text", "message", "title", "name"]
                .compactMap { item[$0]?.stringValue }
                .first { !$0.isEmpty }
                ?? textFragments(from: item["content"]).first
            let text = fallback ?? "暂不支持的对话项目：\(type)"
            return ChatMessage(id: id, role: .tool, text: text, date: date, format: .plain)
        }
    }

    private static func image(id: String, value: String, altText: String, allowLocalPath: Bool) -> ChatImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if ChatImagePolicy.isAllowedDataURL(trimmed) {
            return ChatImage(id: id, source: .dataURL(trimmed), altText: altText)
        }
        if let url = ChatImagePolicy.remoteURL(from: trimmed) {
            return ChatImage(id: id, source: .remoteURL(url.absoluteString), altText: altText)
        }
        if allowLocalPath,
           trimmed.utf8.count <= 4_096,
           trimmed.hasPrefix("/"),
           !trimmed.contains("\0") {
            return ChatImage(id: id, source: .localPath(trimmed), altText: altText)
        }
        return nil
    }

    private static func textFragments(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if let text = value.stringValue { return text.isEmpty ? [] : [text] }
        if let values = value.arrayValue { return values.flatMap { textFragments(from: $0) } }
        if let text = value["text"]?.stringValue, !text.isEmpty { return [text] }
        if let message = value["message"]?.stringValue, !message.isEmpty { return [message] }
        return []
    }

    private static func date(from rawValue: Int?) -> Date? {
        guard let rawValue else { return nil }
        let seconds = rawValue > 10_000_000_000 ? Double(rawValue) / 1_000 : Double(rawValue)
        return Date(timeIntervalSince1970: seconds)
    }
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let threadCount: Int
    let updatedAt: Date?
    let isPinned: Bool
    let isArchived: Bool

    init(
        path: String,
        name: String,
        threadCount: Int,
        updatedAt: Date?,
        isPinned: Bool,
        isArchived: Bool = false
    ) {
        self.path = path
        self.name = name
        self.threadCount = threadCount
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}
