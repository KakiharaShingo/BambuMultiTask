import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BambuMultiTaskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var manager: PrinterManager

    init() {
        let store = SettingsStore()
        _settings = StateObject(wrappedValue: store)
        _manager = StateObject(wrappedValue: PrinterManager(settings: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(manager)
                .environmentObject(settings)
        } label: {
            MenuBarLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Window("設定", id: "settings") {
            SettingsView()
                .environmentObject(settings)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: PrinterManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "printer.fill")
            if let text = manager.shortestRemainingText {
                Text(text).monospacedDigit()
            }
        }
    }
}
