import Foundation

enum ScheduledTaskScheduleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case once
    case interval
    case cron

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "单次"
        case .interval: return "固定间隔"
        case .cron: return "Cron"
        }
    }
}

struct ScheduledTaskSchedule: Codable, Hashable, Sendable {
    var kind: ScheduledTaskScheduleKind
    var runAt: Date?
    var intervalMinutes: Int?
    var cronExpression: String?

    static func once(at date: Date) -> ScheduledTaskSchedule {
        ScheduledTaskSchedule(kind: .once, runAt: date)
    }

    static func interval(minutes: Int) -> ScheduledTaskSchedule {
        ScheduledTaskSchedule(kind: .interval, intervalMinutes: max(1, minutes))
    }

    static func cron(_ expression: String) -> ScheduledTaskSchedule {
        ScheduledTaskSchedule(kind: .cron, cronExpression: expression)
    }

    var summary: String {
        switch kind {
        case .once:
            guard let runAt else { return "未设置时间" }
            return runAt.formatted(date: .abbreviated, time: .shortened)
        case .interval:
            return "每 \(max(1, intervalMinutes ?? 1)) 分钟"
        case .cron:
            return cronExpression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? cronExpression!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "未设置表达式"
        }
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .once:
            guard let runAt, runAt > date else { return nil }
            return runAt
        case .interval:
            return calendar.date(byAdding: .minute, value: max(1, intervalMinutes ?? 1), to: date)
        case .cron:
            guard let expression = try? CronExpression(cronExpression ?? "") else { return nil }
            return expression.nextDate(after: date, calendar: calendar)
        }
    }

    func validationMessage(at date: Date = Date()) -> String? {
        switch kind {
        case .once:
            guard let runAt else { return "请选择执行时间" }
            return runAt > date ? nil : "执行时间必须晚于现在"
        case .interval:
            return (intervalMinutes ?? 0) >= 1 ? nil : "间隔至少为 1 分钟"
        case .cron:
            do {
                _ = try CronExpression(cronExpression ?? "")
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    var validationMessage: String? { validationMessage() }
}

enum ScheduledTaskExecutionState: String, Codable, Sendable {
    case never
    case running
    case succeeded
    case failed

    var title: String {
        switch self {
        case .never: return "尚未执行"
        case .running: return "正在启动"
        case .succeeded: return "已启动"
        case .failed: return "执行失败"
        }
    }
}

struct ScheduledTask: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var prompt: String
    var cwd: String
    var modelID: String?
    var reasoningEffort: String?
    var schedule: ScheduledTaskSchedule
    var isEnabled: Bool
    var createdAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?
    var executionState: ScheduledTaskExecutionState
    var executionMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        cwd: String,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        schedule: ScheduledTaskSchedule,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        executionState: ScheduledTaskExecutionState = .never,
        executionMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.cwd = cwd
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.executionState = executionState
        self.executionMessage = executionMessage
    }

    func validationMessage(at date: Date = Date()) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "任务名称不能为空"
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "执行提示词不能为空"
        }
        if !cwd.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return "项目路径必须是 Mac 上的绝对路径"
        }
        return schedule.validationMessage(at: date)
    }
}

struct CronExpression: Hashable, Sendable {
    let source: String
    private let minute: CronField
    private let hour: CronField
    private let day: CronField
    private let month: CronField
    private let weekday: CronField

    init(_ source: String) throws {
        let fields = source.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw CronExpressionError.fieldCount }
        self.source = fields.joined(separator: " ")
        minute = try CronField(fields[0], allowed: 0...59)
        hour = try CronField(fields[1], allowed: 0...23)
        day = try CronField(fields[2], allowed: 1...31)
        month = try CronField(fields[3], allowed: 1...12)
        weekday = try CronField(fields[4], allowed: 0...7, mapsSevenToZero: true)
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var candidate = calendar.date(bySetting: .second, value: 0, of: date),
              let first = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
        candidate = first
        for _ in 0..<(8 * 366 * 24 * 60) {
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard let candidateMinute = components.minute,
                  let candidateHour = components.hour,
                  let candidateDay = components.day,
                  let candidateMonth = components.month,
                  let calendarWeekday = components.weekday else { return nil }
            let cronWeekday = calendarWeekday - 1
            let dayMatches: Bool
            if day.isWildcard && weekday.isWildcard {
                dayMatches = true
            } else if day.isWildcard {
                dayMatches = weekday.contains(cronWeekday)
            } else if weekday.isWildcard {
                dayMatches = day.contains(candidateDay)
            } else {
                dayMatches = day.contains(candidateDay) || weekday.contains(cronWeekday)
            }
            if minute.contains(candidateMinute),
               hour.contains(candidateHour),
               month.contains(candidateMonth),
               dayMatches {
                return candidate
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }
}

private struct CronField: Hashable, Sendable {
    let values: Set<Int>
    let isWildcard: Bool

    init(_ source: String, allowed: ClosedRange<Int>, mapsSevenToZero: Bool = false) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CronExpressionError.invalidField(source) }
        isWildcard = trimmed == "*"
        var parsed = Set<Int>()
        for component in trimmed.split(separator: ",").map(String.init) {
            let stepParts = component.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard stepParts.count <= 2,
                  let step = stepParts.count == 2 ? Int(stepParts[1]) : 1,
                  step > 0 else { throw CronExpressionError.invalidField(source) }
            let base = stepParts[0]
            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = allowed
            } else if base.contains("-") {
                let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                guard rangeParts.count == 2,
                      let lower = Int(rangeParts[0]),
                      let upper = Int(rangeParts[1]),
                      allowed.contains(lower), allowed.contains(upper), lower <= upper else {
                    throw CronExpressionError.invalidField(source)
                }
                bounds = lower...upper
            } else {
                guard let value = Int(base), allowed.contains(value) else {
                    throw CronExpressionError.invalidField(source)
                }
                bounds = value...value
            }
            for value in stride(from: bounds.lowerBound, through: bounds.upperBound, by: step) {
                parsed.insert(mapsSevenToZero && value == 7 ? 0 : value)
            }
        }
        guard !parsed.isEmpty else { throw CronExpressionError.invalidField(source) }
        values = parsed
    }

    func contains(_ value: Int) -> Bool { values.contains(value) }
}

enum CronExpressionError: LocalizedError, Equatable {
    case fieldCount
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .fieldCount: return "Cron 必须包含 5 段：分钟 小时 日期 月份 星期"
        case .invalidField(let field): return "Cron 字段无效：\(field)"
        }
    }
}
