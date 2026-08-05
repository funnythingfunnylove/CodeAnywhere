import AppKit
import SwiftUI

final class CodeAnywhereMacApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (() -> Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shutdownHandler?() != false else { return .terminateCancel }
        shutdownHandler = nil
        return .terminateNow
    }
}

@main
struct CodeAnywhereMacApp: App {
    @NSApplicationDelegateAdaptor(CodeAnywhereMacApplicationDelegate.self) private var appDelegate
    @StateObject private var model = MacAppModel()

    var body: some Scene {
        Window("CodeAnywhere Mac", id: "main") {
            MacDashboardView(model: model)
                .onAppear {
                    configureApplicationDelegate()
                    model.handleInitialLaunch()
                }
        }
        .defaultSize(width: 780, height: 760)

        MenuBarExtra("CodeAnywhere Mac", systemImage: "terminal.fill") {
            MacMenuBarView(model: model)
                .onAppear {
                    configureApplicationDelegate()
                    model.handleInitialLaunch()
                }
        }
        .menuBarExtraStyle(.menu)
    }

    private func configureApplicationDelegate() {
        appDelegate.shutdownHandler = { [weak model] in
            model?.shutdownForQuit() ?? true
        }
    }
}

private struct MacMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: MacAppModel

    var body: some View {
        Button("打开主界面") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Text(model.server.state.label)
        Text(model.monitor.status.label)

        if model.server.state.isRunning {
            Button("停止服务器") { model.stopServer() }
        } else {
            Button("启动服务器") { model.startServer() }
        }

        Divider()

        Button("退出 CodeAnywhere Mac") {
            NSApp.terminate(nil)
        }
    }
}
