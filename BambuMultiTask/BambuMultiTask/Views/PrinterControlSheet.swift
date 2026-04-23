import SwiftUI

struct PrinterControlSheet: View {
    @ObservedObject var client: BambuMQTTClient
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false
    @State private var fan: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            playbackSection
            Divider()
            lightFanSection
            Spacer()
        }
        .padding(18)
        .frame(width: 420, height: 400)
        .onAppear { fan = Double(client.status.chamberFanSpeed) }
        .alert("印刷を停止しますか？", isPresented: $confirmStop) {
            Button("停止する", role: .destructive) {
                client.stopPrint()
                dismiss()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("進行中の印刷を中止します。この操作は元に戻せません。")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.green.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "slider.horizontal.3").foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(client.printer.name).font(.headline)
                Text(client.status.state.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("印刷コントロール", systemImage: "play.rectangle")
            HStack(spacing: 10) {
                playbackButton(
                    title: "一時停止",
                    systemImage: "pause.fill",
                    color: .orange,
                    enabled: client.status.state == .running || client.status.state == .prepare
                ) {
                    client.pausePrint()
                }
                playbackButton(
                    title: "再開",
                    systemImage: "play.fill",
                    color: .green,
                    enabled: client.status.state == .pause
                ) {
                    client.resumePrint()
                }
                playbackButton(
                    title: "停止",
                    systemImage: "stop.fill",
                    color: .red,
                    enabled: client.status.isPrinting
                ) {
                    confirmStop = true
                }
            }
        }
    }

    private func playbackButton(title: String, systemImage: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .disabled(!enabled)
    }

    private var lightFanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("環境", systemImage: "lightbulb.max")
            Toggle(isOn: Binding(
                get: { client.status.chamberLightOn },
                set: { client.setChamberLight(on: $0) }
            )) {
                Label("チャンバーライト", systemImage: "lightbulb.fill")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("チャンバーファン", systemImage: "fan.fill")
                    Spacer()
                    Text("\(Int(fan / 255 * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $fan, in: 0...255, step: 15) { editing in
                    if !editing {
                        client.setChamberFan(speed255: Int(fan))
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
