import BackgroundTasks
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshIdentifier = "me.fenglei.codeanywhere.refresh"
    private static weak var instance: AppDelegate?
    private var backgroundExecutionIdentifier: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.instance = self
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refreshTask)
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let threadID = response.notification.request.content.userInfo["threadId"] as? String {
            UserDefaults.standard.set(threadID, forKey: StorageKey.pendingThreadID)
            NotificationCenter.default.post(name: .openCodexThread, object: threadID)
        }
        completionHandler()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        startFiniteBackgroundExecution(using: application)
        Self.scheduleBackgroundRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        endFiniteBackgroundExecution(using: application)
    }

    static func backgroundWatchStateChanged() {
        guard let instance else {
            scheduleBackgroundRefresh()
            return
        }
        if BackgroundWatchStore.all().isEmpty {
            instance.endFiniteBackgroundExecution(using: .shared)
        } else {
            scheduleBackgroundRefresh()
        }
    }

    static func scheduleBackgroundRefresh() {
        guard !BackgroundWatchStore.all().isEmpty else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            guard !requests.contains(where: { $0.identifier == refreshIdentifier }) else {
                BackgroundRefreshDiagnostics.recordScheduled()
                return
            }
            let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            do {
                try BGTaskScheduler.shared.submit(request)
                BackgroundRefreshDiagnostics.recordScheduled()
            } catch {
                BackgroundRefreshDiagnostics.recordScheduleFailure(error)
            }
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let operation = Task {
            let success = await BackgroundCompletionMonitor.checkNow()
            if !BackgroundWatchStore.all().isEmpty { scheduleBackgroundRefresh() }
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { operation.cancel() }
    }

    private func startFiniteBackgroundExecution(using application: UIApplication) {
        guard !BackgroundWatchStore.all().isEmpty,
              backgroundExecutionIdentifier == .invalid else { return }
        backgroundExecutionIdentifier = application.beginBackgroundTask(withName: "Finish Codex notification") { [weak self] in
            guard let self else { return }
            self.endFiniteBackgroundExecution(using: application)
        }
    }

    private func endFiniteBackgroundExecution(using application: UIApplication) {
        guard backgroundExecutionIdentifier != .invalid else { return }
        application.endBackgroundTask(backgroundExecutionIdentifier)
        backgroundExecutionIdentifier = .invalid
    }
}

enum BackgroundRefreshDiagnostics {
    private static let scheduledAtKey = "codeanywhere.backgroundRefreshScheduledAt"
    private static let checkedAtKey = "codeanywhere.backgroundRefreshCheckedAt"
    private static let errorKey = "codeanywhere.backgroundRefreshError"

    static func recordScheduled(defaults: UserDefaults = .standard) {
        defaults.set(Date(), forKey: scheduledAtKey)
        defaults.removeObject(forKey: errorKey)
    }

    static func recordCheck(success: Bool, defaults: UserDefaults = .standard) {
        defaults.set(Date(), forKey: checkedAtKey)
        if success { defaults.removeObject(forKey: errorKey) }
    }

    static func recordScheduleFailure(_ error: Error, defaults: UserDefaults = .standard) {
        defaults.set(error.localizedDescription, forKey: errorKey)
    }

    static func snapshot(defaults: UserDefaults = .standard) -> BackgroundRefreshSnapshot {
        BackgroundRefreshSnapshot(
            watchedCount: BackgroundWatchStore.all(defaults: defaults).count,
            scheduledAt: defaults.object(forKey: scheduledAtKey) as? Date,
            checkedAt: defaults.object(forKey: checkedAtKey) as? Date,
            errorMessage: defaults.string(forKey: errorKey)
        )
    }
}

struct BackgroundRefreshSnapshot: Equatable, Sendable {
    let watchedCount: Int
    let scheduledAt: Date?
    let checkedAt: Date?
    let errorMessage: String?
}

actor NotificationManager {
    static let shared = NotificationManager()

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationAuthorizationState(status: settings.authorizationStatus)
    }

    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    func notifyCompletion(title: String, threadID: String) async throws {
        try await add(Self.completionContent(title: title, threadID: threadID), identifier: "codex-\(threadID)")
    }

    func notifyTest() async throws {
        let content = UNMutableNotificationContent()
        content.title = "CodeAnywhere 提醒正常"
        content.body = "Codex 任务完成后会通过这里提醒你。"
        content.sound = .default
        try await add(content, identifier: "codeanywhere-notification-test")
    }

    nonisolated static func completionContent(title: String, threadID: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Codex 已完成"
        content.body = title
        content.sound = .default
        content.userInfo = ["threadId": threadID]
        return content
    }

    private func add(_ content: UNNotificationContent, identifier: String) async throws {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case enabled
    case provisional

    init(status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .provisional: self = .provisional
        case .authorized, .ephemeral: self = .enabled
        @unknown default: self = .notDetermined
        }
    }

    var title: String {
        switch self {
        case .notDetermined: return "尚未设置"
        case .denied: return "已关闭"
        case .enabled: return "已允许"
        case .provisional: return "安静通知"
        }
    }
}

enum BackgroundCompletionMonitor {
    static func checkNow() async -> Bool {
        let watched = BackgroundWatchStore.all()
        guard !watched.isEmpty else {
            BackgroundRefreshDiagnostics.recordCheck(success: true)
            return true
        }
        guard let data = UserDefaults.standard.data(forKey: StorageKey.endpoint),
              let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: data) else {
            BackgroundRefreshDiagnostics.recordCheck(success: false)
            return false
        }
        let client = CodexWebSocketClient(endpoint: endpoint)
        do {
            _ = try await client.connect()
            for item in watched {
                guard !Task.isCancelled else { break }
                let result = try await client.call(method: "thread/read", params: [
                    "threadId": .string(item.id),
                    "includeTurns": .bool(false)
                ])
                let activity = result["thread"]?["status"]?["type"]?.stringValue
                if activity != "active", let completed = BackgroundWatchStore.take(threadID: item.id) {
                    do {
                        try await NotificationManager.shared.notifyCompletion(title: completed.title, threadID: completed.id)
                    } catch {
                        BackgroundWatchStore.add(threadID: completed.id, title: completed.title)
                        throw error
                    }
                }
            }
            await client.disconnect()
            BackgroundRefreshDiagnostics.recordCheck(success: true)
            await MainActor.run { AppDelegate.backgroundWatchStateChanged() }
            return true
        } catch {
            await client.disconnect()
            BackgroundRefreshDiagnostics.recordCheck(success: false)
            return false
        }
    }
}
