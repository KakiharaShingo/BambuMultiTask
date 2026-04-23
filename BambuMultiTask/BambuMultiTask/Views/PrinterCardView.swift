import SwiftUI

struct PrinterCardView: View {
    @ObservedObject var client: BambuMQTTClient
    @EnvironmentObject var discovery: BambuDiscovery
    @State private var showingControl = false

    /// 手動設定の IP、なければ SSDP 自動検出の IP。無ければ nil。
    private var lanIP: String? {
        let manual = client.printer.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return discovery.currentIP(for: client.printer.serialNumber)
    }
    private var isIPAutoDetected: Bool {
        client.printer.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && discovery.currentIP(for: client.printer.serialNumber) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            mainContent
            Divider().opacity(0.35)
            tempRow
            if !client.status.amsTrays.isEmpty {
                amsRow
            }
            if client.status.isPrinting, !client.status.jobName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(client.status.jobName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let err = client.lastError, shouldHighlightError(err) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accentColor.opacity(isActive ? 0.35 : 0.12), lineWidth: 1)
        )
        .shadow(color: accentColor.opacity(isActive ? 0.15 : 0.0), radius: 10, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.25), value: client.status.state)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            showingControl = true
        }
        .help("ダブルクリックで操作パネルを開く")
        .sheet(isPresented: $showingControl) {
            PrinterControlSheet(client: client)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: client.status.state.symbolName)
                    .foregroundStyle(accentColor)
                    .font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(client.printer.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    connectionChip
                    if let ip = lanIP {
                        ipChip(ip)
                    }
                }
            }
            Spacer()
            if client.status.chamberLightOn {
                Image(systemName: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("チャンバーライト点灯中")
            }
            statusChip
        }
    }

    private var connectionChip: some View {
        HStack(spacing: 4) {
            Image(systemName: client.printer.connection == .cloud ? "cloud.fill" : "wifi")
                .font(.system(size: 9, weight: .semibold))
            Text(client.printer.connection == .cloud ? "クラウド" : "LAN")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func ipChip(_ ip: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isIPAutoDetected ? "dot.radiowaves.left.and.right" : "network")
                .font(.system(size: 9, weight: .semibold))
            Text(ip)
                .font(.caption2.weight(.medium).monospacedDigit())
        }
        .foregroundStyle(isIPAutoDetected ? Color.green : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(
            (isIPAutoDetected ? Color.green : Color.secondary)
                .opacity(0.12),
            in: Capsule()
        )
        .help(isIPAutoDetected ? "SSDP 自動検出: \(ip)" : "設定済み: \(ip)")
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
            Text(client.status.state.displayName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(accentColor.opacity(0.12), in: Capsule())
        .foregroundStyle(accentColor)
    }

    @ViewBuilder private var mainContent: some View {
        if client.status.isPrinting {
            progressSection
        } else {
            idleSection
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(client.status.progressPercent)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accentColor)
                Text("%")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(client.status.remainingTimeText)
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(client.status.progressPercent), total: 100)
                .tint(accentColor)
            HStack {
                if client.status.totalLayers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption2)
                        Text("\(client.status.currentLayer) / \(client.status.totalLayers)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: client.status.printSpeed.symbolName)
                    Text(client.status.printSpeed.displayName)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }

    private var idleSection: some View {
        HStack(spacing: 10) {
            Image(systemName: idleIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor.opacity(0.7))
            Text(idleMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var idleIcon: String {
        switch client.status.state {
        case .offline: return "wifi.slash"
        case .finish: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pause: return "pause.circle.fill"
        default: return "moon.zzz.fill"
        }
    }

    private var idleMessage: String {
        if client.status.state == .offline {
            return client.lastError ?? "接続中…"
        }
        switch client.status.state {
        case .finish: return "印刷が完了しました"
        case .failed: return "印刷が失敗しました"
        case .pause: return "一時停止中"
        case .prepare: return "印刷の準備中"
        default: return "待機中"
        }
    }

    private var tempRow: some View {
        HStack(spacing: 10) {
            tempTile(
                icon: "flame.fill",
                label: "ノズル",
                current: client.status.nozzleTemp,
                target: client.status.nozzleTarget,
                tint: .orange
            )
            tempTile(
                icon: "square.grid.2x2.fill",
                label: "ベッド",
                current: client.status.bedTemp,
                target: client.status.bedTarget,
                tint: .pink
            )
        }
    }

    private func tempTile(icon: String, label: String, current: Double, target: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text(String(format: "%.0f°", current))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("/ \(Int(target))°")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var amsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(client.status.amsTrays, id: \.slot) { tray in
                amsChip(tray)
            }
            Spacer()
        }
    }

    private func amsChip(_ tray: AMSTray) -> some View {
        let color: Color = {
            if let c = tray.color {
                return Color(red: c.r, green: c.g, blue: c.b)
            }
            return Color.gray.opacity(0.4)
        }()
        return HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
            if let remain = tray.remainingPercent, remain >= 0 {
                Text("\(remain)%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .help("スロット\(tray.slot) \(tray.materialType ?? "")")
    }

    private func shouldHighlightError(_ err: String) -> Bool {
        // ユーザーが把握・対応すべきエラーだけハイライト
        let keywords = ["認証失敗", "LAN モード", "ハードウェア故障", "Access Code"]
        return keywords.contains(where: err.contains)
    }

    private var accentColor: Color {
        switch client.status.state {
        case .running: return .green
        case .prepare: return .blue
        case .pause: return .orange
        case .finish: return .mint
        case .failed: return .red
        case .offline: return .gray
        default: return .gray
        }
    }

    private var isActive: Bool {
        switch client.status.state {
        case .running, .prepare, .pause: return true
        default: return false
        }
    }
}
