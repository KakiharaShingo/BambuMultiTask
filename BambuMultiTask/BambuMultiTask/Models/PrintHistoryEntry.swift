import Foundation

struct PrintHistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var printerName: String
    var printerSerial: String
    var jobName: String
    var state: String          // FINISH / FAILED
    var startedAt: Date?
    var endedAt: Date
    var totalLayers: Int
    var durationMinutes: Int?  // 推定印刷時間

    var isSuccess: Bool { state == "FINISH" }
}
