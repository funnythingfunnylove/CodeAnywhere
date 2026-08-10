import Foundation

public enum MonitoredThreadState: String, Codable, Sendable {
    case active, completed, failed, interrupted, unknown

    public init(codexStatus: String) {
        switch codexStatus.lowercased() {
        case "active", "inprogress", "running": self = .active
        case "completed": self = .completed
        case "systemerror", "failed", "error", "errored": self = .failed
        case "interrupted", "cancelled", "canceled": self = .interrupted
        default: self = .unknown
        }
    }

    public var shouldNotify: Bool { self == .completed || self == .failed }
}

public enum CompletionTerminalDetail {
    public static func redacted(from error: JSONValue?) -> String? {
        guard let error else { return nil }
        let values = [error["message"]?.stringValue, error["additionalDetails"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        var value = String(values.joined(separator: "\n").prefix(2_000))
        let patterns = [
            #"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret)\s*[:=]\s*["']?)[^\s"',};&]+"#,
            #"(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|key)=)[^&#;\s]+"#,
            #"(?i)(cookie\s*:\s*)[^\r\n]+"#,
            #"(\b)sk-[A-Za-z0-9_-]{8,}\b"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "$1<redacted>")
        }
        return value
    }
}

public struct MonitoredThreadSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public let state: MonitoredThreadState
    public let turnID: String?
    public let terminalDetail: String?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let rawDate = json["updatedAt"]?.intValue else { return nil }
        self.id = id
        let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = json["preview"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = json["cwd"]?.stringValue ?? ""
        if let name, !name.isEmpty { title = name }
        else if let preview, !preview.isEmpty { title = preview }
        else {
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            title = project.isEmpty ? "Codex 对话" : project
        }
        let seconds = rawDate > 10_000_000_000 ? Double(rawDate) / 1_000 : Double(rawDate)
        updatedAt = Date(timeIntervalSince1970: seconds)
        let latestTurn = json["turns"]?.arrayValue?.last
        turnID = latestTurn?["id"]?.stringValue
        let rawStatus = latestTurn?["status"]?.stringValue
            ?? json["status"]?["type"]?.stringValue
            ?? json["status"]?.stringValue
            ?? "unknown"
        state = MonitoredThreadState(codexStatus: rawStatus)
        terminalDetail = CompletionTerminalDetail.redacted(from: latestTurn?["error"] ?? json["status"])
    }
}

public struct PendingCompletion: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String
    public let title: String
    public let body: String
    public let detail: String?
    public let deepLink: String
    public let state: MonitoredThreadState
    public let updatedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
}

public struct CompletionState: Codable, Equatable, Sendable {
    public var baseline: Date
    public var active: Set<String>
    public var pending: [String: PendingCompletion]
    public var delivered: [String: Date]

    public init(baseline: Date = Date()) {
        self.baseline = baseline
        active = []
        pending = [:]
        delivered = [:]
    }
}

public struct FileCompletionStateStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> CompletionState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(CompletionState.self, from: data) else {
            return CompletionState()
        }
        return state
    }

    public func save(_ state: CompletionState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum CompletionDetector {
    public static func observe(
        snapshots: [MonitoredThreadSnapshot],
        state: inout CompletionState,
        now: Date = Date(),
        maximumAttempts: Int = 5
    ) {
        let previousBaseline = state.baseline
        for snapshot in snapshots {
            if snapshot.state == .active { state.active.insert(snapshot.id); continue }
            let wasActive = state.active.remove(snapshot.id) != nil
            guard snapshot.state.shouldNotify, let turnID = snapshot.turnID, !turnID.isEmpty else { continue }
            guard wasActive || snapshot.updatedAt > previousBaseline else { continue }
            let id = StableIdentifier.digest("\(snapshot.id)|turn|\(turnID)")
            guard state.delivered[id] == nil, state.pending[id] == nil else { continue }
            state.pending[id] = PendingCompletion(
                id: id, threadID: snapshot.id,
                title: snapshot.state == .failed ? "Codex 执行失败" : "Codex 已完成",
                body: snapshot.title, detail: snapshot.terminalDetail,
                deepLink: deepLink(for: snapshot.id), state: snapshot.state,
                updatedAt: snapshot.updatedAt, attempts: 0, nextAttemptAt: now
            )
        }
        if let latest = snapshots.map(\.updatedAt).max() { state.baseline = max(state.baseline, latest) }
        state.pending = state.pending.mapValues { value in
            var value = value
            if value.attempts >= maximumAttempts { value.nextAttemptAt = .distantFuture }
            return value
        }
    }

    public static func observe(_ event: CodexTerminatedEvent, state: inout CompletionState, title: String, now: Date = Date()) {
        state.active.remove(event.threadID)
        guard event.status.shouldNotify else { return }
        let id = StableIdentifier.digest("\(event.threadID)|turn|\(event.turnID)")
        guard state.delivered[id] == nil, state.pending[id] == nil else { return }
        state.pending[id] = PendingCompletion(
            id: id, threadID: event.threadID,
            title: event.status == .failed ? "Codex 执行失败" : "Codex 已完成",
            body: title, detail: event.detail,
            deepLink: deepLink(for: event.threadID), state: event.status,
            updatedAt: now, attempts: 0, nextAttemptAt: now
        )
    }

    public static func deepLink(for threadID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "codeanywhere://thread/\(threadID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }
}
