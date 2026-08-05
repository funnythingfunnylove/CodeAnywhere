import SwiftUI

@main
struct CodeAnywhereApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = RemoteCodexStore()
    @AppStorage(StorageKey.appearance) private var appearanceValue = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(appearance.preferredColorScheme)
                .task { await store.connectIfConfigured() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await store.connectIfConfigured() }
                }
        }
    }
}
