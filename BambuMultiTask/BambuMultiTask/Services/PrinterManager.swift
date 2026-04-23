import Foundation
import Combine

@MainActor
final class PrinterManager: ObservableObject {
    @Published private(set) var clients: [BambuMQTTClient] = []
    private var cancellables: Set<AnyCancellable> = []
    private var cloudCancellables: Set<AnyCancellable> = []
    private let settings: SettingsStore
    let history: PrintHistoryStore
    weak var cloudSession: BambuCloudSession? {
        didSet { observeCloud() }
    }

    init(settings: SettingsStore, history: PrintHistoryStore) {
        self.settings = settings
        self.history = history
        sync(with: settings.printers)
        settings.$printers
            .sink { [weak self] printers in
                Task { @MainActor in self?.sync(with: printers) }
            }
            .store(in: &cancellables)
    }

    // MARK: - 一括操作
    func pauseAll() {
        for c in clients where c.status.isPrinting {
            c.pausePrint()
        }
    }
    func resumeAll() {
        for c in clients where c.status.state == .pause {
            c.resumePrint()
        }
    }
    func stopAll() {
        for c in clients where c.status.isPrinting {
            c.stopPrint()
        }
    }

    private func observeCloud() {
        cloudCancellables.removeAll()
        guard let session = cloudSession else { return }

        session.$tokens
            .removeDuplicates()
            .sink { [weak self, weak session] tokens in
                guard let self, let session else { return }
                if let t = tokens {
                    Task { @MainActor in
                        if t.userID.isEmpty {
                            await session.refreshUserIDIfNeeded()
                        }
                        try? await session.fetchDevices()
                        self.reconnectCloudClients()
                    }
                } else {
                    for c in self.clients where c.printer.connection == .cloud {
                        c.disconnect()
                    }
                }
            }
            .store(in: &cloudCancellables)

        session.$devices
            .sink { [weak self] devices in
                self?.importCloudDevices(devices)
            }
            .store(in: &cloudCancellables)

        // 起動時に既にログイン済みなら即同期
        if session.tokens != nil {
            Task { @MainActor [weak session, weak self] in
                guard let session else { return }
                if session.tokens?.userID.isEmpty == true {
                    await session.refreshUserIDIfNeeded()
                }
                try? await session.fetchDevices()
                self?.reconnectCloudClients()
            }
        }
    }

    private func importCloudDevices(_ devices: [BambuCloudDevice]) {
        let existing = Set(settings.printers.map(\.serialNumber))
        for d in devices where !existing.contains(d.dev_id) {
            let printer = Printer(
                name: d.name,
                connection: .cloud,
                host: "",
                serialNumber: d.dev_id,
                accessCode: d.dev_access_code ?? ""
            )
            settings.addOrUpdate(printer)
        }
    }

    private func reconnectCloudClients() {
        for c in clients where c.printer.connection == .cloud {
            c.connect()
        }
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
            guard let session = cloudSession, let tokens = session.tokens, !tokens.userID.isEmpty else { return nil }
            return MQTTCredentials(host: session.mqttHost, username: tokens.mqttUsername, password: tokens.accessToken)
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
        client.onStateTransition = { [weak self] printer, from, to, status in
            guard let self else { return }
            Task { @MainActor in
                self.history.append(
                    PrintHistoryEntry(
                        printerName: printer.name,
                        printerSerial: printer.serialNumber,
                        jobName: status.jobName,
                        state: to.rawValue,
                        startedAt: nil,
                        endedAt: Date(),
                        totalLayers: status.totalLayers,
                        durationMinutes: nil
                    )
                )
            }
        }
        client.connect()
        return client
    }
}
