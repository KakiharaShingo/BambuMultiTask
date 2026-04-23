import Foundation

enum PrinterState: String {
    case idle = "IDLE"
    case prepare = "PREPARE"
    case running = "RUNNING"
    case pause = "PAUSE"
    case finish = "FINISH"
    case failed = "FAILED"
    case offline = "OFFLINE"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .idle: return "待機中"
        case .prepare: return "準備中"
        case .running: return "印刷中"
        case .pause: return "一時停止"
        case .finish: return "完了"
        case .failed: return "失敗"
        case .offline: return "オフライン"
        case .unknown: return "不明"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "moon.zzz"
        case .prepare: return "hourglass"
        case .running: return "printer.fill"
        case .pause: return "pause.circle"
        case .finish: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum PrintSpeed: Int, CaseIterable, Identifiable {
    case silent = 1
    case standard = 2
    case sport = 3
    case ludicrous = 4

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .silent: return "静音"
        case .standard: return "標準"
        case .sport: return "スポーツ"
        case .ludicrous: return "最高速"
        }
    }
    var symbolName: String {
        switch self {
        case .silent: return "tortoise.fill"
        case .standard: return "figure.walk"
        case .sport: return "figure.run"
        case .ludicrous: return "hare.fill"
        }
    }
}

struct AMSTray: Equatable, Hashable {
    var slot: Int
    var colorHex: String?
    var materialType: String?
    var remainingPercent: Int?

    var color: (r: Double, g: Double, b: Double)? {
        guard let hex = colorHex else { return nil }
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 { s = String(s.prefix(6)) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return (r, g, b)
    }
}

struct PrinterStatus: Equatable {
    var state: PrinterState = .offline
    var progressPercent: Int = 0
    var remainingMinutes: Int = 0
    var currentLayer: Int = 0
    var totalLayers: Int = 0
    var nozzleTemp: Double = 0
    var nozzleTarget: Double = 0
    var bedTemp: Double = 0
    var bedTarget: Double = 0
    var chamberTemp: Double = 0
    var jobName: String = ""
    var lastUpdate: Date?

    // 拡張: 制御系
    var printSpeed: PrintSpeed = .standard
    var chamberLightOn: Bool = false
    var chamberFanSpeed: Int = 0 // 0-255
    var amsTrays: [AMSTray] = []

    var isPrinting: Bool {
        state == .running || state == .prepare || state == .pause
    }

    var remainingTimeText: String {
        guard isPrinting, remainingMinutes > 0 else { return "—" }
        let h = remainingMinutes / 60
        let m = remainingMinutes % 60
        if h > 0 { return "\(h)時間\(m)分" }
        return "\(m)分"
    }
}
