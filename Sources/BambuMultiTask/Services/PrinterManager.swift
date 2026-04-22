import Foundation
import Combine

@MainActor
final class PrinterManager: ObservableObject {
    @Published private(set) var clients: [BambuMQTTClient] = []
    private var cancellables: Set<AnyCancellable> = []
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        sync(with: settings.printers)
        settings.$printers
            .sink { [weak self] printers in
                Task { @MainActor in self?.sync(with: printers) }
            }
            .store(in: &cancellables)
    }

    func refreshAll() {
        for c in clients { c.requestFullStatus() }
    }

    var shortestRemainingText: String? {
        let printing = clients
            .map(\.status)
            .filter { $0.isPrinting && $0.remainingMinutes > 0 }
        guard let min = printing.min(by: { $0.remainingMinutes < $1.remainingMinutes }) else {
            return nil
        }
        return min.shortRemainingText
    }

    private func sync(with printers: [Printer]) {
        let existingIDs = Set(clients.map(\.printer.id))
        let newIDs = Set(printers.map(\.id))

        for client in clients where !newIDs.contains(client.printer.id) {
            client.disconnect()
        }
        clients.removeAll { !newIDs.contains($0.printer.id) }

        for printer in printers where !existingIDs.contains(printer.id) {
            let client = BambuMQTTClient(printer: printer)
            clients.append(client)
            client.connect()
        }

        for (idx, printer) in printers.enumerated() {
            if let existing = clients.first(where: { $0.printer.id == printer.id }),
               existing.printer != printer {
                existing.disconnect()
                let replacement = BambuMQTTClient(printer: printer)
                if let i = clients.firstIndex(where: { $0.printer.id == printer.id }) {
                    clients[i] = replacement
                }
                replacement.connect()
            }
            _ = idx
        }
    }
}
