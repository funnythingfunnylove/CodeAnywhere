import CryptoKit
import Foundation

enum MonitoredThreadState: String, Codable, Sendable {
    case active
    case completed
    case failed
    case interrupted
    case unknown

    init(codexStatus: String) {
        switch codexStatus.lowercased() {
        case "active", "inprogress", "running": self = .active
        case "completed": self = .completed
        case "systemerror", "failed", "error", "errored": self = .failed
        case "interrupted", "cancelled", "canceled": self = .interrupted
        default: self = .unknown
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted: return true
        case .active, .unknown: return false
        }
    }
}

enum CompletionTerminalDetail {
    private static let sensitivePatterns = [
        #"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret)\s*[:=]\s*[\"']?)[^\s\"',};&]+"#,
        #"(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|key)=)[^&#;\s]+"#,
        #"(?i)(cookie\s*:\s*)[^\r\n]+"#,
        #"(\b)sk-[A-Za-z0-9_-]{8,}\b"#
    ]

    static func redacted(from error: MacJSONValue?) -> String? {
        guard let error else { return nil }
        let message = error["message"]?.stringValue
        let additionalDetails = error["additionalDetails"]?.stringValue
        let value = [message, additionalDetails]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !value.isEmpty else { return nil }
        var redacted = ProcessLogRedactor.redact(String(value.prefix(2_000)))
        for pattern in sensitivePatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        return redacted
    }
}

struct MonitoredThreadSnapshot: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let state: MonitoredThreadState
    let turnID: String?
    let terminalDetail: String?

    init?(json: MacJSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = json["preview"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = json["cwd"]?.stringValue ?? ""
        if let name, !name.isEmpty {
            title = name
        } else if let preview, !preview.isEmpty {
            title = preview
        } else {
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            title = project.isEmpty ? "Codex 对话" : project
        }

        guard let rawDate = json["updatedAt"]?.intValue else { return nil }
        let seconds = rawDate > 10_000_000_000 ? Double(rawDate) / 1_000 : Double(rawDate)
        updatedAt = Date(timeIntervalSince1970: seconds)
        let latestTurn = json["turns"]?.arrayValue?.last
        turnID = latestTurn?["id"]?.stringValue
        if let rawTurnStatus = latestTurn?["status"]?.stringValue {
            state = MonitoredThreadState(codexStatus: rawTurnStatus)
        } else {
            let rawThreadStatus = json["status"]?["type"]?.stringValue
                ?? json["status"]?.stringValue
                ?? "unknown"
            state = rawThreadStatus.lowercased() == "active" ? .active : .unknown
        }
        terminalDetail = CompletionTerminalDetail.redacted(
            from: latestTurn?["error"] ?? json["status"]
        )
    }

    init(
        id: String,
        title: String,
        updatedAt: Date,
        state: MonitoredThreadState,
        turnID: String? = nil,
        terminalDetail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.state = state
        self.turnID = turnID
        self.terminalDetail = terminalDetail
    }
}

struct ActiveThreadObservation: Codable, Equatable, Sendable {
    let firstObservedAt: Date
    var latestUpdatedAt: Date
}

struct PendingCompletionDelivery: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let threadID: String
    let title: String
    let body: String
    let detail: String?
    let group: String
    let deepLink: String
    let terminalState: MonitoredThreadState
    let threadUpdatedAt: Date
    var attempts: Int
    var nextAttemptAt: Date

    init(
        id: String,
        threadID: String,
        title: String,
        body: String,
        detail: String? = nil,
        group: String,
        deepLink: String,
        terminalState: MonitoredThreadState,
        threadUpdatedAt: Date,
        attempts: Int,
        nextAttemptAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.detail = detail
        self.group = group
        self.deepLink = deepLink
        self.terminalState = terminalState
        self.threadUpdatedAt = threadUpdatedAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }
}

struct CompletionNotificationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let threadID: String
    let title: String
    let body: String
    let detail: String?
    let terminalState: MonitoredThreadState
    let threadUpdatedAt: Date
    let deliveredAt: Date

    init(
        id: String,
        threadID: String,
        title: String,
        body: String,
        detail: String? = nil,
        terminalState: MonitoredThreadState,
        threadUpdatedAt: Date,
        deliveredAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.detail = detail
        self.terminalState = terminalState
        self.threadUpdatedAt = threadUpdatedAt
        self.deliveredAt = deliveredAt
    }
}

struct CompletionMonitorState: Codable, Equatable, Sendable {
    var baseline: Date
    var active: [String: ActiveThreadObservation]
    var pending: [String: PendingCompletionDelivery]
    var delivered: [String: Date]
    var notificationHistory: [CompletionNotificationRecord]

    init(
        baseline: Date,
        active: [String: ActiveThreadObservation] = [:],
        pending: [String: PendingCompletionDelivery] = [:],
        delivered: [String: Date] = [:],
        notificationHistory: [CompletionNotificationRecord] = []
    ) {
        self.baseline = baseline
        self.active = active
        self.pending = pending
        self.delivered = delivered
        self.notificationHistory = notificationHistory
    }

    private enum CodingKeys: String, CodingKey {
        case baseline, active, pending, delivered, notificationHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try container.decode(Date.self, forKey: .baseline)
        active = try container.decodeIfPresent([String: ActiveThreadObservation].self, forKey: .active) ?? [:]
        pending = try container.decodeIfPresent([String: PendingCompletionDelivery].self, forKey: .pending) ?? [:]
        delivered = try container.decodeIfPresent([String: Date].self, forKey: .delivered) ?? [:]
        notificationHistory = try container.decodeIfPresent(
            [CompletionNotificationRecord].self,
            forKey: .notificationHistory
        ) ?? []
    }
}

enum CompletionDetector {
    static func prepareForMonitoring(
        state: inout CompletionMonitorState,
        now: Date,
        maximumAttempts: Int
    ) {
        for id in state.pending.keys {
            guard var delivery = state.pending[id], delivery.terminalState.isTerminal else { continue }
            delivery.nextAttemptAt = delivery.attempts < maximumAttempts ? now : .distantFuture
            state.pending[id] = delivery
        }
    }

    static func observe(
        snapshots: [MonitoredThreadSnapshot],
        state: inout CompletionMonitorState,
        now: Date
    ) {
        let previousBaseline = state.baseline
        for snapshot in snapshots {
            if snapshot.state == .active {
                if var observation = state.active[snapshot.id] {
                    observation.latestUpdatedAt = max(observation.latestUpdatedAt, snapshot.updatedAt)
                    state.active[snapshot.id] = observation
                } else {
                    state.active[snapshot.id] = ActiveThreadObservation(
                        firstObservedAt: now,
                        latestUpdatedAt: snapshot.updatedAt
                    )
                }
                continue
            }

            let wasActive = state.active.removeValue(forKey: snapshot.id) != nil
            guard snapshot.state.isTerminal,
                  let turnID = snapshot.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !turnID.isEmpty else { continue }
            let firstAppearedAfterBaseline = snapshot.updatedAt > previousBaseline
            guard wasActive || firstAppearedAfterBaseline else { continue }

            let eventID = stableEventID(threadID: snapshot.id, turnID: turnID)
            guard state.delivered[eventID] == nil, state.pending[eventID] == nil else { continue }
            state.pending[eventID] = PendingCompletionDelivery(
                id: eventID,
                threadID: snapshot.id,
                title: notificationTitle(for: snapshot.state),
                body: snapshot.title,
                detail: snapshot.terminalDetail,
                group: "CodeAnywhere",
                deepLink: deepLink(for: snapshot.id),
                terminalState: snapshot.state,
                threadUpdatedAt: snapshot.updatedAt,
                attempts: 0,
                nextAttemptAt: now
            )
        }
        if let latestUpdate = snapshots.map(\.updatedAt).max() {
            state.baseline = max(state.baseline, latestUpdate)
        }
    }

    static func observeTurnTerminated(
        _ event: MacCodexTurnTerminatedEvent,
        title: String,
        state: inout CompletionMonitorState,
        now: Date
    ) {
        state.active.removeValue(forKey: event.threadID)
        let eventID = stableEventID(threadID: event.threadID, turnID: event.turnID)
        guard state.delivered[eventID] == nil, state.pending[eventID] == nil else { return }
        guard event.status.isTerminal else { return }
        state.pending[eventID] = PendingCompletionDelivery(
            id: eventID,
            threadID: event.threadID,
            title: notificationTitle(for: event.status),
            body: title,
            detail: event.detail,
            group: "CodeAnywhere",
            deepLink: deepLink(for: event.threadID),
            terminalState: event.status,
            threadUpdatedAt: now,
            attempts: 0,
            nextAttemptAt: now
        )
    }

    static func markDelivered(
        eventID: String,
        state: inout CompletionMonitorState,
        at date: Date,
        maximumHistory: Int = 2_000
    ) {
        let delivery = state.pending.removeValue(forKey: eventID)
        state.delivered[eventID] = date
        if let delivery {
            state.notificationHistory.removeAll { $0.id == eventID }
            state.notificationHistory.append(
                CompletionNotificationRecord(
                    id: delivery.id,
                    threadID: delivery.threadID,
                    title: delivery.title,
                    body: delivery.body,
                    detail: delivery.detail,
                    terminalState: delivery.terminalState,
                    threadUpdatedAt: delivery.threadUpdatedAt,
                    deliveredAt: date
                )
            )
            state.notificationHistory.sort { $0.deliveredAt > $1.deliveredAt }
            if state.notificationHistory.count > 500 {
                state.notificationHistory.removeLast(state.notificationHistory.count - 500)
            }
        }
        if state.delivered.count > maximumHistory {
            let oldest = state.delivered.sorted { $0.value < $1.value }
            for entry in oldest.prefix(state.delivered.count - maximumHistory) {
                state.delivered.removeValue(forKey: entry.key)
            }
        }
    }

    static func clearNotificationHistory(state: inout CompletionMonitorState) {
        state.notificationHistory.removeAll()
    }

    static func stableEventID(for snapshot: MonitoredThreadSnapshot) -> String {
        stableEventID(threadID: snapshot.id, turnID: snapshot.turnID ?? "")
    }

    private static func stableEventID(threadID: String, turnID: String) -> String {
        let source = "\(threadID)|turn|\(turnID)"
        return BarkNotificationIdentifier.digest(source)
    }

    static func deepLink(for threadID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "codeanywhere://thread/\(encoded)"
    }

    private static func notificationTitle(for state: MonitoredThreadState) -> String {
        switch state {
        case .completed: return "Codex 已完成"
        case .failed: return "Codex 执行失败"
        case .interrupted: return "Codex 已中断"
        case .active, .unknown: return "Codex 状态已更新"
        }
    }
}

struct DeliveryRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    static let standard = DeliveryRetryPolicy(
        maximumAttempts: 5,
        initialDelay: 15,
        maximumDelay: 300
    )

    func nextAttemptDate(afterAttempt attempt: Int, now: Date) -> Date? {
        guard attempt < maximumAttempts else { return nil }
        let exponent = max(0, attempt - 1)
        let delay = min(maximumDelay, initialDelay * pow(2, Double(exponent)))
        return now.addingTimeInterval(delay)
    }
}

protocol CompletionStatePersisting: Sendable {
    func load(now: Date) -> CompletionMonitorState
    func save(_ state: CompletionMonitorState) throws
}

struct FileCompletionStateStore: CompletionStatePersisting, Sendable {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        fileURL = base
            .appendingPathComponent("CodeAnywhere Mac", isDirectory: true)
            .appendingPathComponent("completion-state.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(now: Date) -> CompletionMonitorState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(CompletionMonitorState.self, from: data) else {
            return CompletionMonitorState(baseline: now)
        }
        return state
    }

    func save(_ state: CompletionMonitorState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
