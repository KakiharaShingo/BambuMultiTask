import Foundation

struct Printer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var serialNumber: String
    var accessCode: String

    init(id: UUID = UUID(), name: String, host: String, serialNumber: String, accessCode: String) {
        self.id = id
        self.name = name
        self.host = host
        self.serialNumber = serialNumber
        self.accessCode = accessCode
    }
}
