import Foundation

enum PrinterConnection: String, Codable, CaseIterable, Identifiable {
    case lan
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lan: return "LAN (ローカル)"
        case .cloud: return "クラウド"
        }
    }
}

struct Printer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var connection: PrinterConnection
    var host: String
    var serialNumber: String
    var accessCode: String

    init(
        id: UUID = UUID(),
        name: String,
        connection: PrinterConnection = .lan,
        host: String = "",
        serialNumber: String,
        accessCode: String = ""
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.host = host
        self.serialNumber = serialNumber
        self.accessCode = accessCode
    }
}
