import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var cloud: BambuCloudSession
    @EnvironmentObject var manager: PrinterManager
    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable { case printers, cloud }
    @State private var tab: Tab = .printers

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .printers: PrintersTab()
                case .cloud: CloudTab()
                }
            }
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            Button("完了") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
                .padding(12)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("プリンタ", systemImage: "printer.fill", value: .printers)
            tabButton("クラウド", systemImage: "cloud.fill", value: .cloud)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tabButton(_ title: String, systemImage: String, value: Tab) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color.green.opacity(0.18) : .clear)
                )
                .foregroundStyle(selected ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Printers tab

private struct PrintersTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var discovery: BambuDiscovery
    @State private var selection: Printer.ID?
    @State private var editing: Printer?
    @State private var showingDiscovery = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .sheet(isPresented: $showingDiscovery) {
            DiscoveredPrintersSheet(
                discovered: Array(discovery.discovered.values)
                    .sorted { $0.serial < $1.serial },
                existingSerials: Set(settings.printers.map(\.serialNumber)),
                onApply: { selected in
                    for disc in selected {
                        applyDiscovered(disc)
                    }
                    showingDiscovery = false
                },
                onCancel: { showingDiscovery = false }
            )
            .frame(width: 540, height: 440)
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
            .frame(width: 480, height: 400)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if settings.printers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "printer")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("プリンタなし")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(settings.printers) { printer in
                        HStack(spacing: 10) {
                            Image(systemName: printer.connection == .cloud ? "cloud.fill" : "wifi")
                                .font(.system(size: 12))
                                .foregroundStyle(printer.connection == .cloud ? .blue : .green)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(printer.name).font(.callout.weight(.medium))
                                Text(printer.serialNumber.isEmpty ? "未設定" : printer.serialNumber)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(printer.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    editing = Printer(name: "新しいプリンタ", serialNumber: "")
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
                Button {
                    showingDiscovery = true
                } label: {
                    Label("\(discovery.discovered.count)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.medium))
                }
                .help("LAN内で検出された Bambu プリンタを確認・追加")
                .disabled(discovery.discovered.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 230)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func applyDiscovered(_ disc: BambuDiscovery.DiscoveredPrinter) {
        // 既存機器があれば host を更新、無ければ新規登録
        if let existing = settings.printers.first(where: { $0.serialNumber == disc.serial }) {
            var updated = existing
            updated.host = disc.ip
            settings.addOrUpdate(updated)
        } else {
            let printer = Printer(
                name: disc.name ?? (disc.model.map { "\($0)" } ?? "Bambu \(disc.serial.prefix(6))"),
                connection: .cloud,
                host: disc.ip,
                serialNumber: disc.serial,
                accessCode: ""
            )
            settings.addOrUpdate(printer)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let printer = settings.printers.first(where: { $0.id == id }) {
            PrinterEditor(printer: printer) { updated in
                settings.addOrUpdate(updated)
            }
            .id(printer.id)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("プリンタを選択してください")
                    .font(.headline)
                Text("左のリストから選ぶか ＋ ボタンで追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Printer editor

private struct PrinterEditor: View {
    @State private var draft: Printer
    @EnvironmentObject var discovery: BambuDiscovery
    private let onSave: (Printer) -> Void

    init(printer: Printer, onSave: @escaping (Printer) -> Void) {
        _draft = State(initialValue: printer)
        self.onSave = onSave
    }

    private var discoveredIP: String? {
        guard !draft.serialNumber.isEmpty else { return nil }
        return discovery.currentIP(for: draft.serialNumber)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionCard(title: "基本情報", icon: "info.circle.fill", tint: .blue) {
                    labeledField("名前") {
                        TextField("", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("接続方式") {
                        Picker("", selection: $draft.connection) {
                            ForEach(PrinterConnection.allCases) { c in
                                Text(c.displayName).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    labeledField("シリアル番号") {
                        TextField("例: 01P00A123456789", text: $draft.serialNumber)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if draft.connection == .lan {
                    sectionCard(title: "LAN 接続", icon: "wifi", tint: .green) {
                        labeledField("IP アドレス") {
                            ipAddressField
                        }
                        labeledField("Access Code") {
                            SecureField("8 桁の数字", text: $draft.accessCode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        hintText("プリンタ本体 → 設定 → ネットワーク → LAN Only Mode で確認できます。")
                    }
                } else {
                    sectionCard(title: "クラウド接続", icon: "cloud.fill", tint: .blue) {
                        hintText("「クラウド」タブで Bambu アカウントにログインすると、印刷ステータスと操作はクラウド経由で接続されます。")
                        labeledField("LAN IP（内蔵カメラ用・任意）") {
                            ipAddressField
                        }
                        hintText("A1 / A1 Mini / P2S / X1 / X1C の内蔵カメラは LAN IP 経由で直接視聴します。プリンタ本体 → ネットワーク設定で IP が確認できます。Access Code は自動取得済み。")
                    }
                }

                sectionCard(title: "外部カメラ URL (任意)", icon: "video.fill", tint: .purple) {
                    labeledField("カメラ URL") {
                        TextField("http://camera.local/stream.mjpg", text: $draft.cameraURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    hintText("外部 IP カメラ等を使う場合のみ。URL を設定すると LAN IP より優先されます。MJPEG / JPEG スナップショット両対応。")
                }

                HStack {
                    Spacer()
                    Button {
                        onSave(draft)
                    } label: {
                        Label("保存", systemImage: "checkmark")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var ipAddressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("192.168.x.x", text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let ip = discoveredIP, ip != draft.host {
                    Button {
                        draft.host = ip
                    } label: {
                        Label("自動検出を適用", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
            }
            if let ip = discoveredIP {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Text("SSDP 検出: ")
                        .foregroundStyle(.secondary)
                    Text(ip)
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                    if ip == draft.host {
                        Text("（適用中）")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            } else if !draft.serialNumber.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.tertiary)
                    Text("同一 LAN で自動検出されていません")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func hintText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canSave: Bool {
        guard !draft.name.isEmpty, !draft.serialNumber.isEmpty else { return false }
        if draft.connection == .lan {
            return !draft.host.isEmpty && !draft.accessCode.isEmpty
        }
        return true
    }
}

// MARK: - Cloud tab

private struct CloudTab: View {
    @EnvironmentObject var cloud: BambuCloudSession
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var manager: PrinterManager
    @EnvironmentObject var studioBridge: BambuStudioBridge

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                regionCard
                if cloud.isLoggedIn {
                    accountCard
                    devicesCard
                } else {
                    loginCard
                }
                studioBridgeCard
                if let errorText {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorText)
                            .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
    }

    private var regionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.blue)
                Text("地域").font(.headline)
            }
            Picker("", selection: $cloud.region) {
                ForEach(BambuRegion.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.green)
                Text("Bambu アカウントでログイン").font(.headline)
            }
            Text("API は非公式のため仕様変更で動作しなくなる可能性があります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                TextField("メールアドレス", text: $email)
                    .textFieldStyle(.roundedBorder)

                if needsCode {
                    TextField("認証コード (メール受信)", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Button {
                            Task { await submitCode() }
                        } label: {
                            Label(loading ? "送信中…" : "コードでログイン", systemImage: "arrow.right.circle.fill")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(loading || code.isEmpty)

                        Button("コードを再送") { Task { await sendCode() } }
                            .disabled(loading || email.isEmpty)
                    }
                } else {
                    SecureField("パスワード", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            Task { await submitPassword() }
                        } label: {
                            Label(loading ? "ログイン中…" : "ログイン", systemImage: "arrow.right.circle.fill")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(loading || email.isEmpty || password.isEmpty)

                        Button("メールコードでログイン") { Task { await sendCode() } }
                            .disabled(loading || email.isEmpty)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var accountCard: some View {
        let uid = cloud.tokens?.userID ?? ""
        let hasToken = !(cloud.tokens?.accessToken.isEmpty ?? true)
        let uidOK = !uid.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle().fill(.green.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ログイン中").font(.headline)
                    Text(cloud.mqttHost).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    cloud.logout()
                } label: {
                    Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            HStack(spacing: 10) {
                statusBadge(
                    label: "accessToken",
                    value: hasToken ? "取得済み" : "なし",
                    ok: hasToken
                )
                statusBadge(
                    label: "userID",
                    value: uidOK ? uid : "取得失敗",
                    ok: uidOK
                )
            }

            if !uidOK && hasToken {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("userID が取得できないため MQTT 認証ができません。「再接続」を押すとプロフィール API で再試行します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await fetchDevices() }
                } label: {
                    Label(busy ? "取得中…" : "デバイス一覧を取得", systemImage: "arrow.clockwise")
                }
                .disabled(busy)

                Button {
                    Task {
                        await cloud.refreshUserIDIfNeeded()
                        manager.reconnectAll()
                    }
                } label: {
                    Label("クラウド機を再接続", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait").foregroundStyle(.blue)
                Text("登録機器").font(.headline)
                Text("(\(cloud.devices.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    importDevices()
                } label: {
                    Label("プリンタ一覧に追加", systemImage: "plus")
                }
                .disabled(cloud.devices.isEmpty)
            }
            if cloud.devices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("デバイス未取得").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 6) {
                    ForEach(cloud.devices) { d in
                        deviceRow(d)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private func deviceRow(_ d: BambuCloudDevice) -> some View {
        let online = d.online ?? false
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill((online ? Color.green : Color.gray).opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: online ? "wifi" : "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(online ? .green : .gray)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name).font(.callout.weight(.medium))
                Text(d.dev_id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(online ? "オンライン" : "オフライン")
                .font(.caption.weight(.medium))
                .foregroundStyle(online ? .green : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((online ? Color.green : Color.gray).opacity(0.12), in: Capsule())
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
    }

    private func statusBadge(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
    }

    // MARK: - Studio bridge card

    private var studioBridgeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.purple)
                Text("BambuStudio カメラ連携").font(.headline)
                Spacer()
                studioStatusBadge
            }

            Picker("利用", selection: Binding(
                get: { studioBridge.mode },
                set: { studioBridge.mode = $0; studioBridge.probe() }
            )) {
                ForEach(BambuStudioBridge.UseMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            studioStatusDetail

            HStack(spacing: 8) {
                Button {
                    studioBridge.probe()
                } label: {
                    Label("再検出", systemImage: "arrow.clockwise")
                }
                Button {
                    studioBridge.selectPluginFolder()
                } label: {
                    Label("フォルダを選択…", systemImage: "folder")
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    @ViewBuilder private var studioStatusBadge: some View {
        switch studioBridge.status {
        case .unknown, .searching:
            Label("検出中…", systemImage: "ellipsis.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .notFound, .needsUserSelection:
            Label("未検出", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.orange)
        case .detected:
            Label("検出", systemImage: "magnifyingglass.circle.fill")
                .font(.caption).foregroundStyle(.blue)
        case .loaded:
            Label("利用可能", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .error:
            Label("エラー", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var studioStatusDetail: some View {
        switch studioBridge.status {
        case .unknown, .searching:
            Text("状態を確認中…")
                .font(.caption).foregroundStyle(.secondary)
        case .notFound:
            Text("BambuStudio が見つかりません。BambuStudio をインストールするか、「フォルダを選択…」でプラグインの場所を指定してください。")
                .font(.caption).foregroundStyle(.secondary)
        case .needsUserSelection(let msg):
            Text(msg)
                .font(.caption).foregroundStyle(.secondary)
        case .detected(let path, let ver):
            VStack(alignment: .leading, spacing: 3) {
                Text("検出: \(ver ?? "不明")").font(.caption)
                Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("※ dlopen は未実施。「利用する」設定で読み込み試行されます。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .loaded(let path, let ver):
            VStack(alignment: .leading, spacing: 3) {
                Text("ロード成功: BambuStudio \(ver ?? "不明")").font(.caption).foregroundStyle(.green)
                Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("Phase 2 で実際のストリーム取得を実装予定。現状は存在/ロード確認のみ。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .error(let msg):
            Text(msg)
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Actions

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

// MARK: - Discovered printers sheet

private struct DiscoveredPrintersSheet: View {
    let discovered: [BambuDiscovery.DiscoveredPrinter]
    let existingSerials: Set<String>
    let onApply: ([BambuDiscovery.DiscoveredPrinter]) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if discovered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(discovered, id: \.serial) { disc in
                            row(disc)
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            footer
        }
        .onAppear {
            // デフォルトで既存機器も選択しておく（IP更新したい場合多いので）
            selection = Set(discovered.map(\.serial))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.green.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LAN 内で検出された Bambu プリンタ")
                    .font(.headline)
                Text("\(discovered.count) 台検出 (SSDP 239.255.255.250:2021)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("検出されたプリンタはありません")
                .font(.headline)
            Text("プリンタの電源が入っていて、同じ LAN にいるか確認してください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func row(_ disc: BambuDiscovery.DiscoveredPrinter) -> some View {
        let isSelected = selection.contains(disc.serial)
        let isExisting = existingSerials.contains(disc.serial)
        return Button {
            if isSelected { selection.remove(disc.serial) } else { selection.insert(disc.serial) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(disc.name ?? "Bambu プリンタ")
                            .font(.callout.weight(.medium))
                        if let model = disc.model {
                            Text(model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        if isExisting {
                            Text("登録済み")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Label(disc.ip, systemImage: "network")
                            .monospacedDigit()
                        Label(disc.serial, systemImage: "number")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.green.opacity(0.08) : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("すべて選択") {
                selection = Set(discovered.map(\.serial))
            }
            Button("選択解除") {
                selection = []
            }
            Spacer()
            Text("\(selection.count) 台を適用")
                .font(.caption).foregroundStyle(.secondary)
            Button("キャンセル") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("適用") {
                let targets = discovered.filter { selection.contains($0.serial) }
                onApply(targets)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
        .padding(14)
    }
}
