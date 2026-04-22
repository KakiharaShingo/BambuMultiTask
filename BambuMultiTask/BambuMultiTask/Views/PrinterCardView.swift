import SwiftUI

struct PrinterCardView: View {
    @ObservedObject var client: BambuMQTTClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: client.status.state.symbolName)
                    .foregroundStyle(stateColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.printer.name).font(.headline)
                    Text(client.printer.connection.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(client.status.state.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(stateColor)
            }

            if client.status.isPrinting {
                ProgressView(value: Double(client.status.progressPercent), total: 100)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(client.status.progressPercent)%")
                        .monospacedDigit()
                        .font(.subheadline.bold())
                    Spacer()
                    Label(client.status.remainingTimeText, systemImage: "clock")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if client.status.totalLayers > 0 {
                    Text("レイヤー \(client.status.currentLayer) / \(client.status.totalLayers)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !client.status.jobName.isEmpty {
                    Text(client.status.jobName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if client.status.state == .offline {
                Text(client.lastError ?? "接続中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                tempLabel(icon: "flame.fill", current: client.status.nozzleTemp, target: client.status.nozzleTarget)
                tempLabel(icon: "square.fill", current: client.status.bedTemp, target: client.status.bedTarget)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tempLabel(icon: String, current: Double, target: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(String(format: "%.0f / %.0f°C", current, target))
                .monospacedDigit()
        }
    }

    private var stateColor: Color {
        switch client.status.state {
        case .running: return .green
        case .prepare: return .blue
        case .pause: return .orange
        case .finish: return .green
        case .failed: return .red
        case .offline: return .gray
        default: return .secondary
        }
    }
}
