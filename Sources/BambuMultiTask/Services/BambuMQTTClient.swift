import Foundation
import Combine
import CocoaMQTT

final class BambuMQTTClient: NSObject, ObservableObject {
    let printer: Printer
    @Published private(set) var status: PrinterStatus = PrinterStatus()
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    private var mqtt: CocoaMQTT?
    private var reconnectWorkItem: DispatchWorkItem?
    private let reportTopic: String
    private let requestTopic: String

    init(printer: Printer) {
        self.printer = printer
        self.reportTopic = "device/\(printer.serialNumber)/report"
        self.requestTopic = "device/\(printer.serialNumber)/request"
        super.init()
    }

    func connect() {
        disconnect()
        let clientID = "BambuMultiTask-\(UUID().uuidString.prefix(8))"
        let client = CocoaMQTT(clientID: clientID, host: printer.host, port: 8883)
        client.username = "bblp"
        client.password = printer.accessCode
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

    func requestFullStatus() {
        let payload = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
        mqtt?.publish(requestTopic, withString: payload, qos: .qos0)
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
            markOffline(reason: "接続拒否: \(ack)")
            scheduleReconnect()
            return
        }
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
            if let name = print["subtask_name"] as? String, !name.isEmpty { s.jobName = name }
            s.lastUpdate = Date()
            self.status = s
        }
    }
}
