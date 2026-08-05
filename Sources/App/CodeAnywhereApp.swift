import SwiftUI

@main
struct CodeAnywhereApp: App {
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
                .onOpenURL { url in
                    guard let threadID = CodeAnywhereDeepLink.threadID(from: url) else { return }
                    Task { await store.requestOpenThread(threadID) }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await store.connectIfConfigured() }
                }
        }
    }
}

enum CodeAnywhereDeepLink {
    static let maximumThreadIDLength = 512

    static func threadID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("codeanywhere") == .orderedSame,
              components.host?.caseInsensitiveCompare("thread") == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.fragment == nil else { return nil }

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix("/"), encodedPath.count > 1 else { return nil }

        let encodedThreadID = encodedPath.dropFirst()
        guard !encodedThreadID.contains("/"),
              let threadID = String(encodedThreadID).removingPercentEncoding,
              !threadID.isEmpty,
              threadID.utf8.count <= maximumThreadIDLength else { return nil }

        return threadID
    }
}
