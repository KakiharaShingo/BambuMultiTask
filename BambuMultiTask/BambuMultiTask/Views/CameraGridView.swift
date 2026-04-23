import SwiftUI
import AppKit

@MainActor
final class CameraCoordinator: ObservableObject {
    @Published private(set) var streams: [UUID: CameraStream] = [:]

    func sync(with printers: [Printer], discovery: BambuDiscovery?, studioBridge: BambuStudioBridge?) {
        let currentIDs = Set(printers.map(\.id))
        for id in streams.keys where !currentIDs.contains(id) {
            streams[id]?.stop()
            streams.removeValue(forKey: id)
        }
        for printer in printers {
            let desiredMode = makeMode(for: printer, discovery: discovery, studioBridge: studioBridge)
            let existing = streams[printer.id]
            if desiredMode == nil {
                existing?.stop()
                streams.removeValue(forKey: printer.id)
                continue
            }
            if let existing, existing.mode == desiredMode { continue }
            existing?.stop()
            guard let stream = makeStream(for: printer, mode: desiredMode!, studioBridge: studioBridge) else { continue }
            streams[printer.id] = stream
            stream.start()
        }
    }

    private func makeMode(for printer: Printer, discovery: BambuDiscovery?, studioBridge: BambuStudioBridge?) -> CameraStream.Mode? {
        let url = printer.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, let u = URL(string: url) {
            return .url(u)
        }
        // LAN IP + accessCode が揃う場合のみカメラ視聴可能。
        // `host` 手動入力 or SSDP 自動検出のいずれかで IP を取得。
        let manualHost = printer.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = printer.accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        let effectiveHost = !manualHost.isEmpty
            ? manualHost
            : (discovery?.currentIP(for: printer.serialNumber) ?? "")
        guard !effectiveHost.isEmpty else { return nil }
        if studioBridge?.isEffectivelyEnabled == true {
            return .bambuStudio(host: effectiveHost, accessCode: code, serial: printer.serialNumber)
        }
        return .bambuNative(host: effectiveHost, accessCode: code)
    }

    private func makeStream(for printer: Printer, mode: CameraStream.Mode, studioBridge: BambuStudioBridge?) -> CameraStream? {
        switch mode {
        case .url(let url):
            return CameraStream(urlString: url.absoluteString, displayName: printer.name)
        case .bambuNative(let host, let code):
            return CameraStream(host: host, accessCode: code, displayName: printer.name)
        case .bambuStudio(let host, let code, let serial):
            guard let bridge = studioBridge else { return nil }
            return CameraStream(host: host, accessCode: code, serial: serial, bridge: bridge, displayName: printer.name)
        }
    }

    func startAll() { for s in streams.values { s.start() } }
    func stopAll()  { for s in streams.values { s.stop() } }
}

struct CameraGridView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var manager: PrinterManager
    @EnvironmentObject var discovery: BambuDiscovery
    @EnvironmentObject var studioBridge: BambuStudioBridge
    @StateObject private var coord = CameraCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            discoveryBar
            ScrollView {
                if settings.printers.isEmpty {
                    emptyState
                } else if !settings.printers.contains(where: { hasCamera($0) }) {
                    noCamerasConfigured
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 340), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(settings.printers) { printer in
                            CameraTile(
                                printer: printer,
                                stream: coord.streams[printer.id],
                                discoveredIP: discovery.currentIP(for: printer.serialNumber)
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear {
            coord.sync(with: settings.printers, discovery: discovery, studioBridge: studioBridge)
        }
        .onDisappear { coord.stopAll() }
        .onChange(of: settings.printers) { _, newValue in
            coord.sync(with: newValue, discovery: discovery, studioBridge: studioBridge)
        }
        .onChange(of: discovery.discovered.keys.sorted()) { _, _ in
            coord.sync(with: settings.printers, discovery: discovery, studioBridge: studioBridge)
        }
        .onChange(of: studioBridge.isEffectivelyEnabled) { _, _ in
            coord.sync(with: settings.printers, discovery: discovery, studioBridge: studioBridge)
        }
    }

    private var discoveryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Text("LAN検出中:")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\(discovery.discovered.count) 台")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
            if !discovery.discovered.isEmpty {
                Text("(\(discovery.discovered.values.map(\.ip).joined(separator: ", ")))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text("SSDP 239.255.255.250:2021")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("表示できるカメラがありません")
                .font(.headline)
            Text("プリンタを追加して再度お試しください")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }

    private var noCamerasConfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("カメラが未設定です")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Label("内蔵カメラ（A1 / A1 Mini / P2S / X1 系）:\nプリンタの LAN IP アドレスを設定すれば、クラウド接続のまま映像を視聴できます。",
                      systemImage: "printer.fill")
                Label("外部カメラ:\n「外部カメラ URL」に MJPEG / JPEG URL を入力。",
                      systemImage: "video.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }

    private func hasCamera(_ p: Printer) -> Bool {
        if !p.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let code = p.accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        let manualHost = p.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualHost.isEmpty { return true }
        return discovery.currentIP(for: p.serialNumber) != nil
    }
}

private struct CameraTile: View {
    let printer: Printer
    let stream: CameraStream?
    let discoveredIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: printer.connection == .cloud ? "cloud.fill" : "wifi")
                    .foregroundStyle(.secondary)
                Text(printer.name).font(.headline).lineLimit(1)
                if discoveredIP != nil, printer.host.isEmpty {
                    Text("自動検出")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                        .help("LAN内で自動検出された IP を使用中")
                }
                Spacer()
                if let stream, stream.isConnected {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                if let s = stream {
                    StreamView(stream: s)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    noCameraConfigured
                }
            }
            if let stream {
                Text(sourceLabel(for: stream))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var noCameraConfigured: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("LAN IP / カメラ URL 未設定")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceLabel(for stream: CameraStream) -> String {
        switch stream.mode {
        case .url(let url): return url.host ?? url.absoluteString
        case .bambuNative(let host, _): return "bambu://\(host):6000 (直接)"
        case .bambuStudio(let host, _, _): return "bambu://\(host):6000 (プラグイン LAN)"
        }
    }
}

private struct StreamView: View {
    @ObservedObject var stream: CameraStream

    var body: some View {
        Group {
            if let img = stream.frame {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(stream.lastError ?? (stream.isConnected ? "映像待機中…" : "接続中…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
