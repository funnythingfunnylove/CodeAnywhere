import Combine
import Foundation

@MainActor
final class ScheduledTaskCatalog: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask]

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            tasks = saved
        } else {
            tasks = []
        }
    }

    func task(id: UUID) -> ScheduledTask? {
        tasks.first { $0.id == id }
    }

    func add(_ task: ScheduledTask, now: Date = Date()) {
        var task = task
        task.nextRunAt = task.isEnabled ? task.schedule.nextDate(after: now) : nil
        task.isEnabled = task.isEnabled && task.nextRunAt != nil
        tasks.append(task)
        sortAndPersist()
    }

    func delete(id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func replace(_ task: ScheduledTask, now: Date = Date()) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return false }
        var replacement = task
        replacement.nextRunAt = replacement.isEnabled
            ? replacement.schedule.nextDate(after: now)
            : nil
        replacement.isEnabled = replacement.isEnabled && replacement.nextRunAt != nil
        tasks[index] = replacement
        sortAndPersist()
        return true
    }

    func setEnabled(_ enabled: Bool, id: UUID, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isEnabled = enabled
        tasks[index].nextRunAt = enabled
            ? tasks[index].schedule.nextDate(after: now)
            : nil
        tasks[index].isEnabled = tasks[index].isEnabled && tasks[index].nextRunAt != nil
        if enabled {
            tasks[index].executionState = .never
            tasks[index].executionMessage = nil
        }
        sortAndPersist()
    }

    func claimDueTasks(at date: Date = Date()) -> [ScheduledTask] {
        var due: [ScheduledTask] = []
        for index in tasks.indices {
            guard tasks[index].isEnabled,
                  let nextRunAt = tasks[index].nextRunAt,
                  nextRunAt <= date else { continue }
            due.append(tasks[index])
            tasks[index].lastRunAt = date
            tasks[index].executionState = .running
            tasks[index].executionMessage = nil
            let next = tasks[index].schedule.nextDate(after: date)
            tasks[index].nextRunAt = next
            if tasks[index].schedule.kind == .once || next == nil {
                tasks[index].isEnabled = false
            }
        }
        if !due.isEmpty { sortAndPersist() }
        return due
    }

    func recordSuccess(id: UUID, message: String) {
        updateResult(id: id, state: .succeeded, message: message)
    }

    func recordFailure(id: UUID, message: String) {
        updateResult(id: id, state: .failed, message: message)
    }

    private func updateResult(id: UUID, state: ScheduledTaskExecutionState, message: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].executionState = state
        tasks[index].executionMessage = String(message.prefix(500))
        persist()
    }

    private func sortAndPersist() {
        tasks.sort {
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
            return ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture)
        }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(tasks), forKey: storageKey)
    }
}
