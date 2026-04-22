import Cocoa
import SwiftUI

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private let settings = SettingsStore()
    private let cloudSession = BambuCloudSession()
    private lazy var manager: PrinterManager = {
        let m = PrinterManager(settings: settings)
        m.cloudSession = cloudSession
        return m
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = manager
        let rootView = ContentView()
            .environmentObject(settings)
            .environmentObject(manager)
            .environmentObject(cloudSession)

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Bambu MultiTask"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        manager.disconnectAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
