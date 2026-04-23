import Foundation
import Combine
import CocoaMQTT

struct MQTTCredentials {
    var host: String
    var port: UInt16 = 8883
    var username: String
    var password: String
}

final class BambuMQTTClient: NSObject, ObservableObject {
    let printer: Printer
    @Published private(set) var status: PrinterStatus = PrinterStatus()
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    var onStateTransition: ((Printer, PrinterState, PrinterState, PrinterStatus) -> Void)?

    private var credentialsProvider: () -> MQTTCredentials?
    private var mqtt: CocoaMQTT?
    private var reconnectWorkItem: DispatchWorkItem?
    private let reportTopic: String
    private let requestTopic: String
    private var sequenceCounter: Int = 0
    private var startedAt: Date?

    init(printer: Printer, credentialsProvider: @escaping () -> MQTTCredentials?) {
        self.printer = printer
        self.credentialsProvider = credentialsProvider
        self.reportTopic = "device/\(printer.serialNumber)/report"
        self.requestTopic = "device/\(printer.serialNumber)/request"
        super.init()
    }

    func connect() {
        disconnect()
        guard let creds = credentialsProvider() else {
            markOffline(reason: "認証情報なし")
            NSLog("BambuMQTT[\(printer.name)]: no credentials available (connection=\(printer.connection.rawValue))")
            return
        }
        NSLog("BambuMQTT[\(printer.name)]: connecting host=\(creds.host) user=\(creds.username)")
        let clientID = "BambuMultiTask-\(UUID().uuidString.prefix(8))"
        let client = CocoaMQTT(clientID: clientID, host: creds.host, port: creds.port)
        client.username = creds.username
        client.password = creds.password
        client.keepAlive = 60
        client.autoReconnect = false
        client.enableSSL = true
        client.allowUntrustCACertificate = true
        client.delegate = self
        self.mqtt = client
        _ = client.connect()
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        mqtt?.disconnect()
        mqtt = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    // MARK: - Commands

    func requestFullStatus() {
        publish(#"{"pushing":{"sequence_id":"0","command":"pushall"}}"#)
    }

    func pausePrint() {
        publish(command("print", ["command": "pause"]))
    }

    func resumePrint() {
        publish(command("print", ["command": "resume"]))
    }

    func stopPrint() {
        publish(command("print", ["command": "stop"]))
    }

    func setPrintSpeed(_ speed: PrintSpeed) {
        publish(command("print", ["command": "print_speed", "param": String(speed.rawValue)]))
    }

    func setChamberLight(on: Bool) {
        let payload: [String: Any] = [
            "system": [
                "sequence_id": nextSeq(),
                "command": "ledctrl",
                "led_node": "chamber_light",
                "led_mode": on ? "on" : "off",
                "led_on_time": 500,
                "led_off_time": 500,
                "loop_times": 0,
                "interval_time": 0
            ]
        ]
        publish(payload)
    }

    func setChamberFan(speed255: Int) {
        let clamped = max(0, min(255, speed255))
        publish(command("print", [
            "command": "gcode_line",
            "param": "M106 P2 S\(clamped)\n"
        ]))
    }

    // MARK: - Plumbing

    private func nextSeq() -> String {
        sequenceCounter += 1
        return String(sequenceCounter)
    }

    private func command(_ root: String, _ inner: [String: Any]) -> [String: Any] {
        var i = inner
        i["sequence_id"] = nextSeq()
        return [root: i]
    }

    private func publish(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        publish(str)
    }

    private func publish(_ payload: String) {
        guard let mqtt else {
            NSLog("BambuMQTT[\(printer.name)]: publish skipped (not connected)")
            return
        }
        mqtt.publish(requestTopic, withString: payload, qos: .qos0)
        NSLog("BambuMQTT[\(printer.name)]: publish \(payload.prefix(80))")
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func markOffline(reason: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.lastError = reason
            self.status.state = .offline
        }
    }
}

extension BambuMQTTClient: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            NSLog("BambuMQTT[\(printer.name)]: connect refused ack=\(ack)")
            // ack の詳細判定: 特に notAuthorized / badUsernameOrPassword はアクセスコード不正の決定打
            let ackStr = "\(ack)".lowercased()
            let reason: String
            if ackStr.contains("notauthorized") || ackStr.contains("badusername") || ackStr.contains("password") {
                reason = (printer.connection == .lan)
                    ? "Access Code 認証失敗。プリンタ本体の最新 Access Code を確認してください"
                    : "クラウド認証失敗。再ログインしてください"
            } else if ackStr.contains("identifierrejected") {
                reason = "クライアント ID 拒否"
            } else if ackStr.contains("serverunavailable") {
                reason = "サーバー一時的利用不可"
            } else {
                reason = "接続拒否: \(ack)"
            }
            markOffline(reason: reason)
            scheduleReconnect()
            return
        }
        NSLog("BambuMQTT[\(printer.name)]: connected")
        DispatchQueue.main.async {
            self.isConnected = true
            self.lastError = nil
        }
        mqtt.subscribe(reportTopic, qos: .qos0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.requestFullStatus()
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        markOffline(reason: err?.localizedDescription ?? "切断")
        scheduleReconnect()
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard let data = message.string?.data(using: .utf8) else { return }
        parse(data: data)
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
}

private extension BambuMQTTClient {
    func parse(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let print = obj["print"] as? [String: Any] else { return }
        let previous = self.status
        DispatchQueue.main.async {
            var s = self.status
            if let p = print["mc_percent"] as? Int { s.progressPercent = p }
            if let p = print["mc_percent"] as? Double { s.progressPercent = Int(p) }
            if let r = print["mc_remaining_time"] as? Int { s.remainingMinutes = r }
            if let r = print["mc_remaining_time"] as? Double { s.remainingMinutes = Int(r) }
            if let g = print["gcode_state"] as? String { s.state = PrinterState(rawValue: g) ?? .unknown }
            if let l = print["layer_num"] as? Int { s.currentLayer = l }
            if let l = print["total_layer_num"] as? Int { s.totalLayers = l }
            if let t = print["nozzle_temper"] as? Double { s.nozzleTemp = t }
            if let t = print["nozzle_target_temper"] as? Double { s.nozzleTarget = t }
            if let t = print["bed_temper"] as? Double { s.bedTemp = t }
            if let t = print["bed_target_temper"] as? Double { s.bedTarget = t }
            if let t = print["chamber_temper"] as? Double { s.chamberTemp = t }
            if let name = print["subtask_name"] as? String, !name.isEmpty { s.jobName = name }

            if let spd = print["spd_lvl"] as? Int, let ps = PrintSpeed(rawValue: spd) {
                s.printSpeed = ps
            }
            if let lights = print["lights_report"] as? [[String: Any]] {
                for l in lights where (l["node"] as? String) == "chamber_light" {
                    s.chamberLightOn = (l["mode"] as? String) == "on"
                }
            }
            if let fans = print["cooling_fan_speed"] as? Int {
                s.chamberFanSpeed = fans
            } else if let big = print["big_fan2_speed"] as? String, let v = Int(big) {
                s.chamberFanSpeed = v
            }
            s.amsTrays = Self.parseAMS(from: print)

            s.lastUpdate = Date()

            // 状態遷移検出
            if previous.state != s.state {
                if s.state == .running, self.startedAt == nil {
                    self.startedAt = Date()
                }
                if (s.state == .finish || s.state == .failed) && previous.isPrinting {
                    self.onStateTransition?(self.printer, previous.state, s.state, s)
                    self.startedAt = nil
                }
                if s.state == .idle { self.startedAt = nil }
            }
            self.status = s
        }
    }

    static func parseAMS(from print: [String: Any]) -> [AMSTray] {
        guard let ams = print["ams"] as? [String: Any],
              let units = ams["ams"] as? [[String: Any]] else { return [] }
        var result: [AMSTray] = []
        for (unitIdx, unit) in units.enumerated() {
            guard let trays = unit["tray"] as? [[String: Any]] else { continue }
            for tray in trays {
                let id = (tray["id"] as? String).flatMap(Int.init) ?? 0
                let slot = unitIdx * 4 + id
                let color = tray["tray_color"] as? String
                let material = tray["tray_type"] as? String
                var remain: Int?
                if let r = tray["remain"] as? Int { remain = r }
                if let r = tray["remain"] as? Double { remain = Int(r) }
                result.append(AMSTray(
                    slot: slot,
                    colorHex: color,
                    materialType: material,
                    remainingPercent: remain
                ))
            }
        }
        return result
    }
}
