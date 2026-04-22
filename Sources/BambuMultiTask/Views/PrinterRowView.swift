import SwiftUI

struct PrinterRowView: View {
    @ObservedObject var client: BambuMQTTClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: client.status.state.symbolName)
                    .foregroundStyle(stateColor)
                    .frame(width: 18)
                Text(client.printer.name)
                    .font(.headline)
                Spacer()
                Text(client.status.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if client.status.isPrinting {
                ProgressView(value: Double(client.status.progressPercent), total: 100)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(client.status.progressPercent)%")
                        .monospacedDigit()
                    Spacer()
                    Text("残り \(client.status.remainingTimeText)")
                        .monospacedDigit()
                }
                .font(.caption)
                if client.status.totalLayers > 0 {
                    Text("レイヤー \(client.status.currentLayer) / \(client.status.totalLayers)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !client.status.jobName.isEmpty {
                    Text(client.status.jobName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if client.status.state == .offline {
                Text(client.lastError ?? "接続中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(String(format: "%.0f / %.0f°C", client.status.nozzleTemp, client.status.nozzleTarget), systemImage: "flame")
                Label(String(format: "%.0f / %.0f°C", client.status.bedTemp, client.status.bedTarget), systemImage: "square")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
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
