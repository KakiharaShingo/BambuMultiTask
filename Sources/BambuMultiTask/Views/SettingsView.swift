import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: Printer.ID?
    @State private var editing: Printer?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(settings.printers) { printer in
                    VStack(alignment: .leading) {
                        Text(printer.name).font(.headline)
                        Text(printer.host).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(printer.id)
                }
            }
            .frame(minWidth: 200)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        editing = Printer(name: "新しいプリンタ", host: "", serialNumber: "", accessCode: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        if let id = selection, let p = settings.printers.first(where: { $0.id == id }) {
                            settings.remove(p)
                            selection = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = selection, let printer = settings.printers.first(where: { $0.id == id }) {
                PrinterEditor(printer: printer) { updated in
                    settings.addOrUpdate(updated)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "printer")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("プリンタを選択").font(.headline)
                    Text("左のリストから選択するか、＋で追加してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                PrinterEditor(printer: draft) { updated in
                    settings.addOrUpdate(updated)
                    selection = updated.id
                    editing = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { editing = nil }
                    }
                }
                .padding()
            }
            .frame(width: 480, height: 360)
        }
        .frame(minWidth: 640, minHeight: 380)
    }
}

struct PrinterEditor: View {
    @State private var draft: Printer
    private let onSave: (Printer) -> Void

    init(printer: Printer, onSave: @escaping (Printer) -> Void) {
        _draft = State(initialValue: printer)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("プリンタ情報") {
                TextField("名前", text: $draft.name)
                TextField("IPアドレス", text: $draft.host)
                TextField("シリアル番号", text: $draft.serialNumber)
                SecureField("Access Code", text: $draft.accessCode)
            }
            Section {
                Text("※ プリンタ本体の 設定 → ネットワーク → LAN Only Mode を有効化すると IP / シリアル / アクセスコードを確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存") { onSave(draft) }
                    .disabled(draft.name.isEmpty || draft.host.isEmpty || draft.serialNumber.isEmpty || draft.accessCode.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }
}
