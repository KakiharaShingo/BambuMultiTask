import Foundation
import AppKit
import Network
import Combine

extension String {
    /// URL query component として安全にエスケープ。既に % 含みの場合も二重エスケープ防止。
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

/// 統合カメラストリーム。3方式を統一 API で扱う:
///  - `.url(URL)`: MJPEG / JPEG スナップショット URL (ESP32-CAM, IP カメラ等)
///  - `.bambuNative(host, accessCode)`: 自前 TLS 実装による LAN IP:6000 への直接接続
///  - `.bambuStudio(host, accessCode, serial)`: BambuStudio プラグイン経由の LAN カメラ（推奨）
@MainActor
final class CameraStream: ObservableObject {
    @Published private(set) var frame: NSImage?
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    enum Mode: Equatable {
        case url(URL)
        case bambuNative(host: String, accessCode: String)
        case bambuStudio(host: String, accessCode: String, serial: String)
    }

    let mode: Mode
    let displayName: String
    weak var studioBridge: BambuStudioBridge?

    // URL mode
    private var urlTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 2.0

    // Bambu native mode
    private var connection: NWConnection?
    private var recvBuffer = Data()
    private var expectedPayload: Int = 0
    private var headerRead: Bool = false

    // Bambu studio plugin mode
    private var pluginClient: BambuStudioPluginClient?

    // MARK: Init

    init?(urlString: String, displayName: String = "") {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let u = URL(string: trimmed) else { return nil }
        self.mode = .url(u)
        self.displayName = displayName.isEmpty ? (u.host ?? u.absoluteString) : displayName
    }

    init(host: String, accessCode: String, displayName: String = "") {
        self.mode = .bambuNative(host: host, accessCode: accessCode)
        self.displayName = displayName.isEmpty ? host : displayName
    }

    init(host: String, accessCode: String, serial: String, bridge: BambuStudioBridge, displayName: String = "") {
        self.mode = .bambuStudio(host: host, accessCode: accessCode, serial: serial)
        self.displayName = displayName.isEmpty ? host : displayName
        self.studioBridge = bridge
    }

    // MARK: Lifecycle

    func start() {
        stop()
        switch mode {
        case .url:
            startURLMode()
        case .bambuNative(let host, let code):
            startBambuNative(host: host, accessCode: code)
        case .bambuStudio(let host, let code, let serial):
            startBambuStudio(host: host, accessCode: code, serial: serial)
        }
    }

    func stop() {
        urlTask?.cancel()
        urlTask = nil
        connection?.cancel()
        connection = nil
        pluginClient?.stop()
        pluginClient = nil
        recvBuffer.removeAll(keepingCapacity: false)
        expectedPayload = 0
        headerRead = false
        isConnected = false
    }

    private func startBambuStudio(host: String, accessCode: String, serial: String) {
        guard let bridge = studioBridge else {
            lastError = "BambuStudio ブリッジ未注入"
            return
        }
        let url = "bambu:///local/\(host)?port=6000&user=bblp&passwd=\(accessCode)&device=\(serial)&version=00.00.00.00"
        runPlugin(bridge: bridge, url: url, label: "\(displayName)[LAN]")
    }

    private func runPlugin(bridge: BambuStudioBridge, url: String, label: String) {
        NSLog("%@", "CameraStream[\(label)]: plugin url=\(url)")
        let client = BambuStudioPluginClient(bridge: bridge)
        self.pluginClient = client
        client.startWithURL(
            url,
            label: label,
            onConnected: { [weak self] in
                Task { @MainActor in
                    self?.isConnected = true
                    self?.lastError = nil
                }
            },
            onFrame: { [weak self] img in
                Task { @MainActor in
                    self?.frame = img
                }
            },
            onError: { [weak self] msg in
                Task { @MainActor in
                    self?.isConnected = false
                    self?.lastError = msg
                    NSLog("%@", "CameraStream[\(self?.displayName ?? "?")]: plugin error: \(msg)")
                }
            }
        )
    }

    deinit {
        urlTask?.cancel()
        connection?.cancel()
    }

    // MARK: URL mode

    private func startURLMode() {
        urlTask = Task { [weak self] in
            await self?.runURLLoop()
        }
    }

    private func runURLLoop() async {
        while !Task.isCancelled {
            do {
                try await attemptURLStream()
            } catch {
                if Task.isCancelled { return }
                self.lastError = error.localizedDescription
                self.isConnected = false
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func attemptURLStream() async throws {
        guard case .url(let url) = mode else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("BambuMultiTask/1.0", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CameraStream", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "HTTPレスポンスなし"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "CameraStream", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        self.isConnected = true
        self.lastError = nil

        if contentType.contains("multipart") {
            try await parseMJPEG(bytes: bytes, contentType: contentType)
        } else {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 10_000_000 { break }
                if Task.isCancelled { return }
            }
            if let img = NSImage(data: data) { self.frame = img }
            try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
        }
    }

    private func parseMJPEG(bytes: URLSession.AsyncBytes, contentType: String) async throws {
        let boundary = Self.extractBoundary(from: contentType) ?? "boundary"
        let boundaryMarker = ("--" + boundary).data(using: .utf8) ?? Data()
        var buf = Data()
        buf.reserveCapacity(512 * 1024)

        for try await byte in bytes {
            if Task.isCancelled { return }
            buf.append(byte)
            if let firstRange = buf.range(of: boundaryMarker) {
                let afterBoundary = firstRange.upperBound
                if let headerEnd = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]),
                                             in: afterBoundary..<buf.endIndex) {
                    let bodyStart = headerEnd.upperBound
                    if let nextRange = buf.range(of: boundaryMarker,
                                                 in: bodyStart..<buf.endIndex) {
                        var end = nextRange.lowerBound
                        while end > bodyStart,
                              buf[end - 1] == 0x0A || buf[end - 1] == 0x0D {
                            end -= 1
                        }
                        let jpegData = buf.subdata(in: bodyStart..<end)
                        if let img = NSImage(data: jpegData) { self.frame = img }
                        buf.removeSubrange(0..<nextRange.lowerBound)
                    }
                }
            }
            if buf.count > 20_000_000 { buf.removeAll(keepingCapacity: false) }
        }
    }

    static func extractBoundary(from contentType: String) -> String? {
        for p in contentType.split(separator: ";") {
            let kv = p.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("boundary=") {
                var v = String(kv.dropFirst("boundary=".count))
                if v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
                if v.hasPrefix("--") { v.removeFirst(2) }
                return v
            }
        }
        return nil
    }

    // MARK: Bambu native mode
    // プロトコル (reverse engineered, bambu-connect などを参照):
    //  1. TCP + TLS (untrusted cert OK) to <host>:6000
    //  2. 80 バイトの認証パケット送信:
    //        [0..3]   uint32 LE 0x40   (msg size = 64)
    //        [4..7]   uint32 LE 0x3000 (type)
    //        [8..15]  0x00 × 8
    //        [16..47] username "bblp" を 32 バイトに \0 パディング
    //        [48..79] accessCode を 32 バイトに \0 パディング
    //  3. 以後フレームループ:
    //        [0..3]   uint32 LE payload size (JPEG バイト数)
    //        [4..15]  未使用 (12 バイト)
    //        [16..16+size]  JPEG 本体

    private func startBambuNative(host: String, accessCode: String) {
        NSLog("CameraStream[\(displayName)]: connecting bambu native \(host):6000")
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOpts.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true
        tcpOpts.connectionTimeout = 10
        let params = NWParameters(tls: tlsOpts, tcp: tcpOpts)
        guard let port = NWEndpoint.Port(rawValue: 6000) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    NSLog("CameraStream[\(self.displayName)]: connected")
                    self.isConnected = true
                    self.lastError = nil
                    self.sendBambuAuth(accessCode: accessCode)
                    self.receiveBambuLoop()
                case .failed(let error):
                    NSLog("CameraStream[\(self.displayName)]: failed: \(error)")
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    // 簡易リトライ
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self.connection === conn {
                        self.startBambuNative(host: host, accessCode: accessCode)
                    }
                case .waiting(let error):
                    NSLog("CameraStream[\(self.displayName)]: waiting: \(error)")
                    self.lastError = "接続待機中: \(error.localizedDescription)"
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func sendBambuAuth(accessCode: String) {
        var packet = Data(count: 80)
        packet[0] = 0x40          // size LE uint32 = 64
        packet[4] = 0x00          // type LE uint32 = 0x3000
        packet[5] = 0x30
        // username "bblp" at offset 16, 32 bytes
        let userBytes = Array("bblp".utf8.prefix(32))
        for (i, b) in userBytes.enumerated() { packet[16 + i] = b }
        // accessCode at offset 48, 32 bytes
        let codeBytes = Array(accessCode.utf8.prefix(32))
        for (i, b) in codeBytes.enumerated() { packet[48 + i] = b }
        connection?.send(content: packet, completion: .contentProcessed { [weak self] err in
            if let err {
                Task { @MainActor in self?.lastError = "auth送信失敗: \(err.localizedDescription)" }
            }
        })
    }

    nonisolated private func receiveBambuLoop() {
        Task { @MainActor in
            guard let conn = self.connection else { return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let error {
                    Task { @MainActor in
                        self.lastError = error.localizedDescription
                        self.isConnected = false
                    }
                    return
                }
                if let data, !data.isEmpty {
                    Task { @MainActor in self.consumeBambu(data) }
                }
                if isComplete {
                    Task { @MainActor in self.isConnected = false }
                    return
                }
                self.receiveBambuLoop()
            }
        }
    }

    private func consumeBambu(_ data: Data) {
        recvBuffer.append(data)
        while true {
            if !headerRead {
                guard recvBuffer.count >= 16 else { return }
                expectedPayload = Int(UInt32(recvBuffer[0]) |
                                      (UInt32(recvBuffer[1]) << 8) |
                                      (UInt32(recvBuffer[2]) << 16) |
                                      (UInt32(recvBuffer[3]) << 24))
                recvBuffer.removeFirst(16)
                headerRead = true
            }
            if expectedPayload <= 0 || expectedPayload > 10_000_000 {
                lastError = "不正なフレーム長 (\(expectedPayload))"
                stop()
                return
            }
            guard recvBuffer.count >= expectedPayload else { return }
            let jpeg = recvBuffer.prefix(expectedPayload)
            recvBuffer.removeFirst(expectedPayload)
            headerRead = false
            expectedPayload = 0
            if let img = NSImage(data: jpeg) { self.frame = img }
        }
    }
}
