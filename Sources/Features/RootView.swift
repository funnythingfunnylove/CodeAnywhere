import SwiftUI

private enum CodeAnywhereTab: Hashable {
    case dash
    case conversations
    case projects
    case tasks
    case settings
}

struct RootView: View {
    @EnvironmentObject private var store: RemoteCodexStore
    @State private var selectedTab = CodeAnywhereTab.dash

    var body: some View {
        Group {
            if store.connectionState.isConnected {
                TabView(selection: $selectedTab) {
                    NavigationStack { DashView() }
                        .tabItem { Label("Dash", systemImage: "gauge.with.dots.needle.67percent") }
                        .tag(CodeAnywhereTab.dash)
                    NavigationStack { SessionsView() }
                        .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                        .tag(CodeAnywhereTab.conversations)
                    NavigationStack { ProjectsView() }
                        .tabItem { Label("项目", systemImage: "folder") }
                        .tag(CodeAnywhereTab.projects)
                    NavigationStack { ScheduledTasksView() }
                        .tabItem { Label("Task", systemImage: "calendar.badge.clock") }
                        .tag(CodeAnywhereTab.tasks)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(CodeAnywhereTab.settings)
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
        .onAppear { selectConversationsForPendingThread() }
        .onChange(of: store.requestedThreadID) { _, _ in
            selectConversationsForPendingThread()
        }
    }

    private func selectConversationsForPendingThread() {
        guard store.requestedThreadID != nil else { return }
        selectedTab = .conversations
    }
}
