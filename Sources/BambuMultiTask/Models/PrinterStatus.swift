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
    var jobName: String = ""
    var lastUpdate: Date?

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

    var shortRemainingText: String {
        guard isPrinting, remainingMinutes > 0 else { return "" }
        let h = remainingMinutes / 60
        let m = remainingMinutes % 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}
