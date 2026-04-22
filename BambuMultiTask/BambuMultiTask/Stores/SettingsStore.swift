import Foundation
import Combine

final class SettingsStore: ObservableObject {
    @Published var printers: [Printer] = [] {
        didSet { save() }
    }

    private let key = "bambuPrinters.v1"

    init() {
        load()
    }

    func addOrUpdate(_ printer: Printer) {
        if let idx = printers.firstIndex(where: { $0.id == printer.id }) {
            printers[idx] = printer
        } else {
            printers.append(printer)
        }
    }

    func remove(_ printer: Printer) {
        printers.removeAll { $0.id == printer.id }
    }

    func replaceAll(_ newPrinters: [Printer]) {
        printers = newPrinters
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([Printer].self, from: data) {
            self.printers = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
