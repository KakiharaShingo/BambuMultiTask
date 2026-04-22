import Foundation
import Combine

@MainActor
final class PrinterManager: ObservableObject {
    @Published private(set) var clients: [BambuMQTTClient] = []
    private var cancellables: Set<AnyCancellable> = []
    private let settings: SettingsStore
    weak var cloudSession: BambuCloudSession?

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

    func reconnectAll() {
        for c in clients { c.connect() }
    }

    func disconnectAll() {
        for c in clients { c.disconnect() }
    }

    private func credentials(for printer: Printer) -> MQTTCredentials? {
        switch printer.connection {
        case .lan:
            guard !printer.host.isEmpty, !printer.accessCode.isEmpty else { return nil }
            return MQTTCredentials(host: printer.host, username: "bblp", password: printer.accessCode)
        case .cloud:
            guard let session = cloudSession, let tokens = session.tokens else { return nil }
            return MQTTCredentials(host: session.mqttHost, username: "u_\(tokens.userID)", password: tokens.accessToken)
        }
    }

    private func sync(with printers: [Printer]) {
        let newIDs = Set(printers.map(\.id))

        for client in clients where !newIDs.contains(client.printer.id) {
            client.disconnect()
        }
        clients.removeAll { !newIDs.contains($0.printer.id) }

        for printer in printers {
            if let existing = clients.first(where: { $0.printer.id == printer.id }) {
                if existing.printer != printer {
                    existing.disconnect()
                    if let idx = clients.firstIndex(where: { $0.printer.id == printer.id }) {
                        clients[idx] = makeClient(for: printer)
                    }
                }
            } else {
                clients.append(makeClient(for: printer))
            }
        }
    }

    private func makeClient(for printer: Printer) -> BambuMQTTClient {
        let client = BambuMQTTClient(printer: printer) { [weak self] in
            self?.credentials(for: printer)
        }
        client.connect()
        return client
    }
}
