import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var history: PrintHistoryStore
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "すべて"
        case success = "成功"
        case failed = "失敗"
        var id: String { rawValue }
    }

    private var filtered: [PrintHistoryEntry] {
        switch filter {
        case .all: return history.entries
        case .success: return history.entries.filter { $0.isSuccess }
        case .failed: return history.entries.filter { !$0.isSuccess }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("印刷履歴", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text("\(filtered.count) 件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Button(role: .destructive) {
                history.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(history.entries.isEmpty)
            .help("すべて削除")
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("まだ履歴がありません")
                .font(.headline)
            Text("印刷完了・失敗時に自動で記録されます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct HistoryRow: View {
    let entry: PrintHistoryEntry
    @EnvironmentObject var history: PrintHistoryStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill((entry.isSuccess ? Color.green : Color.red).opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: entry.isSuccess ? "checkmark" : "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(entry.isSuccess ? Color.green : Color.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.jobName.isEmpty ? "(ジョブ名なし)" : entry.jobName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.printerName)
                    Text("•")
                    Text(formatDate(entry.endedAt))
                    if entry.totalLayers > 0 {
                        Text("•")
                        Text("\(entry.totalLayers) レイヤー")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.isSuccess ? "成功" : "失敗")
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.isSuccess ? Color.green : Color.red)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    (entry.isSuccess ? Color.green : Color.red).opacity(0.12),
                    in: Capsule()
                )
            if hover {
                Button {
                    history.remove(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(hover ? 0.55 : 0.3))
        )
        .onHover { hover = $0 }
    }

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        df.locale = Locale(identifier: "ja_JP")
        return df.string(from: d)
    }
}
