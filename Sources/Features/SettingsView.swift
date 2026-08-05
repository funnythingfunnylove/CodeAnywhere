import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @Environment(\.openURL) private var openURL
    @AppStorage(StorageKey.appearance) private var appearanceValue = AppAppearance.system.rawValue
    @State private var notificationState: NotificationAuthorizationState = .notDetermined
    @State private var notificationFeedback: String?
    @State private var backgroundSnapshot = BackgroundRefreshDiagnostics.snapshot()

    var body: some View {
        ZStack {
            AmbientBackground()
            Form {
                Section("连接") {
                    LabeledContent("IP 地址", value: store.endpoint.host)
                    LabeledContent("端口", value: String(store.endpoint.port))
                    if case .connected(let server) = store.connectionState {
                        LabeledContent("服务端", value: server)
                    }
                    Button("断开连接", role: .destructive) {
                        Task { await store.disconnect() }
                    }
                }
                Section("后台提醒") {
                    LabeledContent("通知权限", value: notificationState.title)
                    LabeledContent("等待提醒", value: "\(backgroundSnapshot.watchedCount) 个任务")
                    if let checkedAt = backgroundSnapshot.checkedAt {
                        LabeledContent("最近后台检查") {
                            Text(checkedAt, format: .relative(presentation: .named))
                        }
                    }
                    notificationAction
                    if let notificationFeedback {
                        Text(notificationFeedback)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("iOS 会按系统调度在后台检查状态；App 保持运行或被系统唤醒时可即时提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage = backgroundSnapshot.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section("外观") {
                    Picker("显示模式", selection: $appearanceValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text((AppAppearance(rawValue: appearanceValue) ?? .system).description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("协议", value: "Codex app-server JSON-RPC v2")
                    LabeledContent("版本", value: "0.1.0")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("设置")
        .task {
            await refreshNotificationState()
            backgroundSnapshot = BackgroundRefreshDiagnostics.snapshot()
        }
    }

    @ViewBuilder
    private var notificationAction: some View {
        switch notificationState {
        case .notDetermined:
            Button("允许消息提醒", systemImage: "bell.badge") {
                Task {
                    notificationState = await NotificationManager.shared.requestAuthorization()
                }
            }
        case .denied:
            Button("打开系统通知设置", systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        case .enabled, .provisional:
            Button("发送测试提醒", systemImage: "bell.and.waves.left.and.right") {
                Task {
                    do {
                        try await NotificationManager.shared.notifyTest()
                        notificationFeedback = "测试提醒已提交，请查看通知横幅或通知中心。"
                    } catch {
                        notificationFeedback = "测试提醒失败：\(error.localizedDescription)"
                    }
                    await refreshNotificationState()
                    backgroundSnapshot = BackgroundRefreshDiagnostics.snapshot()
                }
            }
        }
    }

    private func refreshNotificationState() async {
        notificationState = await NotificationManager.shared.authorizationState()
    }
}
