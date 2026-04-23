import Foundation
import Combine

@MainActor
final class PrintHistoryStore: ObservableObject {
    @Published private(set) var entries: [PrintHistoryEntry] = []
    private let key = "bambuPrintHistory.v1"
    private let maxEntries = 500

    init() { load() }

    func append(_ entry: PrintHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func remove(_ entry: PrintHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([PrintHistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
