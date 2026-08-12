import SwiftUI
import AppKit

@main
struct QopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("Qopy", systemImage: "qrcode") {
            Button("Send Selection to Phone") {
                model.sendSelectionToPhone()
            }
            .keyboardShortcut("c", modifiers: [.control, .option, .command])

            Button("Send Clipboard to Phone") {
                model.sendClipboardToPhone()
            }

            Divider()

            Button("Receive from Phone…") {
                model.openReceiveFromPhone()
            }
            .keyboardShortcut("v", modifiers: [.control, .option, .command])

            Divider()

            Button("Quit Qopy") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        FrontAppTracker.shared.start()
        HotkeyManager.shared.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
