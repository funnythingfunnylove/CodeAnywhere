import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if store.connectionState.isConnected {
                TabView(selection: $selectedTab) {
                    NavigationStack { SessionsView() }
                        .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                        .tag(0)
                    NavigationStack { ProjectsView() }
                        .tabItem { Label("项目", systemImage: "folder") }
                        .tag(1)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(2)
                }
            } else {
                ConnectionView()
            }
        }
        .alert("连接提示", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

