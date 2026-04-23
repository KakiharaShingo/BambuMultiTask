import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = SettingsStore()
    let cloudSession = BambuCloudSession()
    let history = PrintHistoryStore()
    let discovery = BambuDiscovery()
    let studioBridge = BambuStudioBridge()
    lazy var manager: PrinterManager = {
        let m = PrinterManager(settings: settings, history: history)
        m.cloudSession = cloudSession
        return m
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = manager
        discovery.start()
        studioBridge.probe()
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

@main
struct BambuMultiTaskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Bambu MultiTask") {
            ContentView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.manager)
                .environmentObject(appDelegate.cloudSession)
                .environmentObject(appDelegate.history)
                .environmentObject(appDelegate.discovery)
                .environmentObject(appDelegate.studioBridge)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
