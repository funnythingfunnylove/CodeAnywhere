import Foundation

enum BarkInterruptionLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case active
    case timeSensitive
    case passive
    case critical

    var id: String { rawValue }

    private var metadata: (label: String, detail: String) {
        switch self {
        case .active: return ("主动提醒", "立即亮屏显示，适合普通完成提醒")
        case .timeSensitive: return ("时效性", "可在专注模式下显示")
        case .passive: return ("静默收纳", "只加入通知列表，不亮屏")
        case .critical: return ("重要警告", "静音模式下仍可响铃，需 Bark 与系统授权支持")
        }
    }

    var label: String { metadata.label }
    var detail: String { metadata.detail }
}

struct BarkNotification: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let body: String
    let level: BarkInterruptionLevel
    let volume: Int?
    let sound: String?
    let icon: String?
    let group: String
    let url: String
    let id: String
    let usesMarkdown: Bool

    init(
        title: String,
        subtitle: String? = nil,
        body: String,
        level: BarkInterruptionLevel = .active,
        volume: Int? = nil,
        sound: String? = nil,
        icon: String? = nil,
        group: String,
        url: String,
        id: String,
        usesMarkdown: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.volume = volume
        self.sound = sound
        self.icon = icon
        self.group = group
        self.url = url
        self.id = id
        self.usesMarkdown = usesMarkdown
    }
}

struct BarkNotificationStyle: Codable, Equatable, Sendable {
    var titleTemplate: String
    var subtitleTemplate: String
    var bodyTemplate: String
    var group: String
    var level: BarkInterruptionLevel
    var criticalVolume: Int
    var sound: String
    var icon: String
    var usesMarkdown: Bool

    static let legacyCodexDefault = BarkNotificationStyle(
        titleTemplate: "Codex 已完成",
        subtitleTemplate: "{thread}",
        bodyTemplate: "任务已完成 · {time}",
        group: "CodeAnywhere",
        level: .active,
        criticalVolume: 5,
        sound: "",
        icon: "",
        usesMarkdown: false
    )

    static let codexDefault = BarkNotificationStyle(
        titleTemplate: "{status}",
        subtitleTemplate: "{thread}",
        bodyTemplate: "{status} · {time}",
        group: "CodeAnywhere",
        level: .active,
        criticalVolume: 5,
        sound: "",
        icon: "",
        usesMarkdown: false
    )

    func notification(
        threadTitle: String,
        statusTitle: String,
        detail: String? = nil,
        terminalAt: Date,
        url: String,
        id: String
    ) -> BarkNotification {
        let replacements = [
            "{thread}": threadTitle,
            "{status}": statusTitle,
            "{time}": terminalAt.formatted(date: .abbreviated, time: .shortened),
            "{detail}": detail ?? ""
        ]
        let renderedTitle = render(titleTemplate, replacements: replacements, fallback: statusTitle)
        let renderedSubtitle = render(subtitleTemplate, replacements: replacements, fallback: "")
        var renderedBody = render(bodyTemplate, replacements: replacements, fallback: threadTitle)
        if let detail, !detail.isEmpty, !bodyTemplate.contains("{detail}") {
            renderedBody += "\n错误：\(detail)"
        }
        let renderedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedSound = sound.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        return BarkNotification(
            title: renderedTitle,
            subtitle: renderedSubtitle.isEmpty ? nil : renderedSubtitle,
            body: renderedBody,
            level: level,
            volume: level == .critical ? min(10, max(0, criticalVolume)) : nil,
            sound: renderedSound.isEmpty ? nil : renderedSound,
            icon: renderedIcon.isEmpty ? nil : renderedIcon,
            group: renderedGroup.isEmpty ? "CodeAnywhere" : renderedGroup,
            url: url,
            id: id,
            usesMarkdown: usesMarkdown
        )
    }

    private func render(
        _ template: String,
        replacements: [String: String],
        fallback: String
    ) -> String {
        var value = template
        for (token, replacement) in replacements {
            value = value.replacingOccurrences(of: token, with: replacement)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
