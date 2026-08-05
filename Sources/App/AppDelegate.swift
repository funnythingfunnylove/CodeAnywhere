import BackgroundTasks
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshIdentifier = "me.fenglei.codeanywhere.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
        Self.scheduleBackgroundRefresh()
    }

    static func scheduleBackgroundRefresh() {
        guard !BackgroundWatchStore.all().isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let operation = Task {
            let success = await BackgroundCompletionMonitor.checkNow()
            task.setTaskCompleted(success: success)
            if !BackgroundWatchStore.all().isEmpty { scheduleBackgroundRefresh() }
        }
        task.expirationHandler = { operation.cancel() }
    }
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
        guard !watched.isEmpty else { return true }
        guard let data = UserDefaults.standard.data(forKey: StorageKey.endpoint),
              let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: data) else { return false }
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
                if activity != "active", BackgroundWatchStore.remove(threadID: item.id) {
                    try? await NotificationManager.shared.notifyCompletion(title: item.title, threadID: item.id)
                }
            }
            await client.disconnect()
            return true
        } catch {
            await client.disconnect()
            return false
        }
    }
}
