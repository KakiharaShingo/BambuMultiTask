import Foundation
import Network
import Combine

/// Bambu プリンタの SSDP ブロードキャストを傍受して、シリアル番号→LAN IP のマッピングを公開する。
///
/// Bambu プリンタは LAN 内で以下の SSDP NOTIFY パケットを `239.255.255.250:2021` にマルチキャストする:
/// ```
/// NOTIFY * HTTP/1.1
/// HOST: 239.255.255.250:2021
/// Location: 192.168.1.XXX
/// NT: urn:bambulab-com:device:3dprinter:1
/// USN: 00M00XXXXXXXXXX              ← シリアル番号
/// DevModel.bambu.com: A1
/// DevName.bambu.com: ...
/// ```
/// これを拾って `discovered[serial] = ip` として保持するだけのシンプル実装。
@MainActor
final class BambuDiscovery: ObservableObject {
    @Published private(set) var discovered: [String: DiscoveredPrinter] = [:]

    struct DiscoveredPrinter: Equatable {
        var serial: String
        var ip: String
        var model: String?
        var name: String?
        var lastSeen: Date
    }

    private var connectionGroup: NWConnectionGroup?
    private let multicastHost: NWEndpoint.Host = "239.255.255.250"
    private let multicastPort: NWEndpoint.Port = 2021
    private var restartTimer: Timer?

    private var isStarting = false
    func start() {
        // 既に start 済みなら再起動しない（EADDRINUSE 回避）
        if connectionGroup != nil { return }
        if isStarting { return }
        isStarting = true
        defer { isStarting = false }
        stop()
        do {
            let group = try NWMulticastGroup(for: [.hostPort(host: multicastHost, port: multicastPort)])
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let conn = NWConnectionGroup(with: group, using: params)
            conn.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { [weak self] message, content, _ in
                guard let self, let data = content else { return }
                let senderIP = Self.extractSenderIP(from: message)
                Task { @MainActor in
                    self.parse(data, fallbackIP: senderIP)
                }
            }
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .failed(let err):
                        NSLog("BambuDiscovery: group failed: \(err)")
                        self?.scheduleRestart()
                    case .ready:
                        NSLog("BambuDiscovery: listening on 239.255.255.250:2021")
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .global(qos: .utility))
            self.connectionGroup = conn
        } catch {
            NSLog("BambuDiscovery: failed to join multicast: \(error)")
            scheduleRestart()
        }
    }

    func stop() {
        connectionGroup?.cancel()
        connectionGroup = nil
        restartTimer?.invalidate()
        restartTimer = nil
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
    }

    nonisolated private static func extractSenderIP(from message: NWConnectionGroup.Message) -> String? {
        if case let .hostPort(host, _) = message.remoteEndpoint {
            return "\(host)"
        }
        return nil
    }

    private func parse(_ data: Data, fallbackIP: String?) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        // HTTP ライクなヘッダ行をパース
        var headers: [String: String] = [:]
        let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = val }
        }
        // 判定: Bambu デバイスの NOTIFY か？
        let nt = headers["nt"] ?? ""
        let server = headers["server"] ?? ""
        let usn = headers["usn"] ?? ""
        let isBambu = nt.contains("bambulab") || server.lowercased().contains("bambulab")
            || !(headers["devmodel.bambu.com"] ?? "").isEmpty
        guard isBambu, !usn.isEmpty else { return }

        let ip = headers["location"]?.trimmingCharacters(in: .whitespaces) ?? fallbackIP ?? ""
        guard !ip.isEmpty else { return }

        // 既存と同じなら lastSeen だけ更新
        let model = headers["devmodel.bambu.com"]
        let name = headers["devname.bambu.com"]
        let entry = DiscoveredPrinter(
            serial: usn,
            ip: ip,
            model: model,
            name: name,
            lastSeen: Date()
        )
        if discovered[usn] == entry { return } // IP/metadata 変化なし、再代入で余計な publish しないように
        // lastSeen のみが違うケースは頻繁なので、IP が同じなら更新だけ
        if let prev = discovered[usn], prev.ip == ip, prev.model == model, prev.name == name {
            discovered[usn] = entry
            return
        }
        discovered[usn] = entry
        NSLog("BambuDiscovery: serial=\(usn) ip=\(ip) model=\(model ?? "?") name=\(name ?? "?")")
    }

    /// 指定シリアルの最新 IP を返す（存在し、最後に見てから5分以内のものに限定）。
    func currentIP(for serial: String) -> String? {
        guard let d = discovered[serial] else { return nil }
        if Date().timeIntervalSince(d.lastSeen) > 300 { return nil }
        return d.ip
    }
}
