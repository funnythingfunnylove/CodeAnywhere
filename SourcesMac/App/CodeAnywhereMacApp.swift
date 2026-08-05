import AppKit
import SwiftUI

final class CodeAnywhereMacApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (() -> Bool)?

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
        WindowGroup("CodeAnywhere Mac") {
            MacDashboardView(model: model)
                .onAppear {
                    appDelegate.shutdownHandler = { [weak model] in
                        model?.shutdownForQuit() ?? true
                    }
                }
        }
        .defaultSize(width: 780, height: 760)
    }
}
