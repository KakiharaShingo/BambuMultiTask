import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var manager: PrinterManager
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bambu MultiTask")
                    .font(.title3.bold())
                Spacer()
                Button {
                    manager.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("すべて更新")
            }

            if manager.clients.isEmpty {
                VStack(spacing: 8) {
                    Text("プリンタが登録されていません")
                        .foregroundStyle(.secondary)
                    Button("プリンタを追加") {
                        openSettings()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.clients, id: \.printer.id) { client in
                            PrinterRowView(client: client)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()

            HStack {
                Button("設定…") { openSettings() }
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
