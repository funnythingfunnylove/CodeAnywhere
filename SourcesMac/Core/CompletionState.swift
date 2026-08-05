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
        case "active": self = .active
        case "idle", "completed": self = .completed
        case "systemerror", "failed", "error": self = .failed
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

struct MonitoredThreadSnapshot: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let state: MonitoredThreadState

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
        let status = json["status"]?["type"]?.stringValue ?? json["status"]?.stringValue ?? "unknown"
        state = MonitoredThreadState(codexStatus: status)
    }

    init(id: String, title: String, updatedAt: Date, state: MonitoredThreadState) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.state = state
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
    let group: String
    let deepLink: String
    let terminalState: MonitoredThreadState
    let threadUpdatedAt: Date
    var attempts: Int
    var nextAttemptAt: Date
}

struct CompletionMonitorState: Codable, Equatable, Sendable {
    var baseline: Date
    var active: [String: ActiveThreadObservation]
    var pending: [String: PendingCompletionDelivery]
    var delivered: [String: Date]

    init(
        baseline: Date,
        active: [String: ActiveThreadObservation] = [:],
        pending: [String: PendingCompletionDelivery] = [:],
        delivered: [String: Date] = [:]
    ) {
        self.baseline = baseline
        self.active = active
        self.pending = pending
        self.delivered = delivered
    }
}

enum CompletionDetector {
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

            guard snapshot.state.isTerminal else { continue }
            let wasActive = state.active.removeValue(forKey: snapshot.id) != nil
            let firstAppearedAfterBaseline = snapshot.updatedAt > previousBaseline
            guard wasActive || firstAppearedAfterBaseline else { continue }

            let eventID = stableEventID(for: snapshot)
            guard state.delivered[eventID] == nil, state.pending[eventID] == nil else { continue }
            state.pending[eventID] = PendingCompletionDelivery(
                id: eventID,
                threadID: snapshot.id,
                title: notificationTitle(for: snapshot.state),
                body: snapshot.title,
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

    static func markDelivered(
        eventID: String,
        state: inout CompletionMonitorState,
        at date: Date,
        maximumHistory: Int = 2_000
    ) {
        state.pending.removeValue(forKey: eventID)
        state.delivered[eventID] = date
        if state.delivered.count > maximumHistory {
            let oldest = state.delivered.sorted { $0.value < $1.value }
            for entry in oldest.prefix(state.delivered.count - maximumHistory) {
                state.delivered.removeValue(forKey: entry.key)
            }
        }
    }

    static func stableEventID(for snapshot: MonitoredThreadSnapshot) -> String {
        let milliseconds = Int64((snapshot.updatedAt.timeIntervalSince1970 * 1_000).rounded())
        let source = "\(snapshot.id)|\(milliseconds)|\(snapshot.state.rawValue)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return "codeanywhere-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func deepLink(for threadID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "codeanywhere://thread/\(encoded)"
    }

    private static func notificationTitle(for state: MonitoredThreadState) -> String {
        switch state {
        case .completed: return "Codex 已完成"
        case .failed: return "Codex 任务失败"
        case .interrupted: return "Codex 任务已中断"
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
