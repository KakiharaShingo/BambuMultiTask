import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var cloud: BambuCloudSession
    @EnvironmentObject var manager: PrinterManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            PrintersTab()
                .tabItem { Label("プリンタ", systemImage: "printer") }
            CloudTab()
                .tabItem { Label("クラウド", systemImage: "cloud") }
        }
        .frame(width: 640, height: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
    }
}

private struct PrintersTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: Printer.ID?
    @State private var editing: Printer?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.printers) { printer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(printer.name).font(.headline)
                            Text("\(printer.connection.displayName) • \(printer.serialNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(printer.id)
                    }
                }
                Divider()
                HStack {
                    Button {
                        editing = Printer(name: "新しいプリンタ", serialNumber: "")
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection, let p = settings.printers.first(where: { $0.id == id }) {
                            settings.remove(p)
                            selection = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 220)
            Divider()
            if let id = selection, let printer = settings.printers.first(where: { $0.id == id }) {
                PrinterEditor(printer: printer) { updated in
                    settings.addOrUpdate(updated)
                }
                .id(printer.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "printer").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("プリンタを選択").font(.headline)
                    Text("左の＋で追加するか、リストから選んでください")
                        .font(.caption).foregroundStyle(.secondary)
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
            .frame(width: 480, height: 380)
        }
    }
}

private struct PrinterEditor: View {
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
                Picker("接続方式", selection: $draft.connection) {
                    ForEach(PrinterConnection.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                TextField("シリアル番号", text: $draft.serialNumber)
                    .help("プリンタ本体の裏面 または 設定画面で確認")
                if draft.connection == .lan {
                    TextField("IPアドレス", text: $draft.host)
                    SecureField("Access Code", text: $draft.accessCode)
                }
            }
            if draft.connection == .lan {
                Section {
                    Text("※ プリンタの設定 → ネットワーク → LAN Only Mode を有効化すると IP / シリアル / アクセスコード が確認できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("※ クラウド接続を使うには「クラウド」タブで Bambu アカウントにログインしてください。認証情報はログイン済みトークンから自動で使用されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("保存") { onSave(draft) }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
    }

    private var canSave: Bool {
        guard !draft.name.isEmpty, !draft.serialNumber.isEmpty else { return false }
        if draft.connection == .lan {
            return !draft.host.isEmpty && !draft.accessCode.isEmpty
        }
        return true
    }
}

private struct CloudTab: View {
    @EnvironmentObject var cloud: BambuCloudSession
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var manager: PrinterManager

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("地域", selection: $cloud.region) {
                    ForEach(BambuRegion.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                if cloud.isLoggedIn {
                    loggedInSection
                } else {
                    loginSection
                }

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bambu アカウントでログイン")
                .font(.headline)
            Text("API は非公式のため仕様変更で動作しなくなる可能性があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("メールアドレス", text: $email)
                .textFieldStyle(.roundedBorder)
            if needsCode {
                TextField("認証コード (メール受信)", text: $code)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(loading ? "送信中…" : "コードでログイン") {
                        Task { await submitCode() }
                    }
                    .disabled(loading || code.isEmpty)
                    Button("コードを再送") {
                        Task { await sendCode() }
                    }
                    .disabled(loading || email.isEmpty)
                }
            } else {
                SecureField("パスワード", text: $password)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(loading ? "ログイン中…" : "パスワードでログイン") {
                        Task { await submitPassword() }
                    }
                    .disabled(loading || email.isEmpty || password.isEmpty)
                    Button("メールコードでログイン") {
                        Task { await sendCode() }
                    }
                    .disabled(loading || email.isEmpty)
                }
            }
        }
    }

    private var loggedInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ログイン中", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("ログアウト") {
                    cloud.logout()
                }
            }
            HStack {
                Button(busy ? "取得中…" : "デバイス一覧を取得") {
                    Task { await fetchDevices() }
                }
                .disabled(busy)
                Button("取得したデバイスをプリンタ一覧に追加") {
                    importDevices()
                }
                .disabled(cloud.devices.isEmpty)
            }
            if !cloud.devices.isEmpty {
                Divider()
                Text("登録機器 (\(cloud.devices.count))")
                    .font(.subheadline)
                ForEach(cloud.devices) { d in
                    HStack {
                        Image(systemName: (d.online ?? false) ? "circle.fill" : "circle")
                            .foregroundStyle((d.online ?? false) ? .green : .secondary)
                            .font(.caption)
                        Text(d.name).font(.body)
                        Spacer()
                        Text(d.dev_id).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func submitPassword() async {
        errorText = nil; loading = true
        defer { loading = false }
        do {
            try await cloud.login(email: email, password: password)
            password = ""
        } catch BambuCloudError.needsVerification {
            needsCode = true
            errorText = "メール認証コードが必要です。コードを送信してください。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func sendCode() async {
        errorText = nil; loading = true
        defer { loading = false }
        do {
            try await cloud.requestEmailCode(email: email)
            needsCode = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func submitCode() async {
        errorText = nil; loading = true
        defer { loading = false }
        do {
            try await cloud.loginWithEmailCode(email: email, code: code)
            code = ""
            needsCode = false
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func fetchDevices() async {
        errorText = nil; busy = true
        defer { busy = false }
        do {
            try await cloud.fetchDevices()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importDevices() {
        let existingSerials = Set(settings.printers.map(\.serialNumber))
        for d in cloud.devices where !existingSerials.contains(d.dev_id) {
            let printer = Printer(
                name: d.name,
                connection: .cloud,
                host: "",
                serialNumber: d.dev_id,
                accessCode: d.dev_access_code ?? ""
            )
            settings.addOrUpdate(printer)
        }
        manager.reconnectAll()
    }
}
