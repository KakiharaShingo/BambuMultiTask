import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var manager: PrinterManager
    @EnvironmentObject var cloud: BambuCloudSession
    @EnvironmentObject var history: PrintHistoryStore
    @State private var showingSettings = false
    @State private var tab: MainTab = .dashboard
    @State private var confirmBulk: BulkConfirm?

    enum MainTab: Hashable { case dashboard, cameras, history }

    struct BulkConfirm: Identifiable {
        enum Kind { case pause, stop }
        var id: String { "\(kind)" }
        let kind: Kind
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                tabBar
                Divider().opacity(0.3)
                content
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
                .environmentObject(settings)
                .environmentObject(cloud)
                .environmentObject(manager)
        }
        .alert(item: $confirmBulk) { c in
            switch c.kind {
            case .pause:
                return Alert(
                    title: Text("全台を一時停止"),
                    message: Text("現在印刷中のすべての機器を一時停止します。"),
                    primaryButton: .default(Text("一時停止")) { manager.pauseAll() },
                    secondaryButton: .cancel()
                )
            case .stop:
                return Alert(
                    title: Text("全台の印刷を停止"),
                    message: Text("印刷中のすべての機器を停止します。元に戻せません。"),
                    primaryButton: .destructive(Text("全台停止")) { manager.stopAll() },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.green, .teal],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: .green.opacity(0.3), radius: 6, x: 0, y: 3)
                Image(systemName: "printer.filled.and.paper")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Bambu MultiTask")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text("\(manager.clients.count) 台")
                    Text("•")
                    Text("\(activeCount) 稼働中")
                        .foregroundStyle(activeCount > 0 ? .green : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            if cloud.isLoggedIn { cloudBadge }

            Menu {
                Button {
                    manager.refreshAll()
                } label: { Label("全機更新", systemImage: "arrow.clockwise") }
                Button {
                    manager.resumeAll()
                } label: { Label("全機再開", systemImage: "play.fill") }
                    .disabled(!hasPaused)
                Divider()
                Button {
                    confirmBulk = BulkConfirm(kind: .pause)
                } label: { Label("全機一時停止", systemImage: "pause.fill") }
                    .disabled(!hasPrinting)
                Button(role: .destructive) {
                    confirmBulk = BulkConfirm(kind: .stop)
                } label: { Label("全機停止", systemImage: "stop.fill") }
                    .disabled(!hasPrinting)
            } label: {
                Label("一括", systemImage: "rectangle.3.group")
            }
            .help("一括操作")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("設定")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var cloudBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Image(systemName: "cloud.fill").font(.caption)
            Text("クラウド接続").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.green.opacity(0.12), in: Capsule())
        .foregroundStyle(.green)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton("ダッシュボード", systemImage: "square.grid.2x2", value: .dashboard)
            tabButton("カメラ", systemImage: "video.fill", value: .cameras)
            tabButton("履歴", systemImage: "clock.arrow.circlepath", value: .history)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func tabButton(_ title: String, systemImage: String, value: MainTab) -> some View {
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

    @ViewBuilder private var content: some View {
        switch tab {
        case .dashboard: dashboard
        case .cameras: CameraGridView()
        case .history: HistoryView()
        }
    }

    private var dashboard: some View {
        Group {
            if manager.clients.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 340), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(manager.clients, id: \.printer.id) { client in
                            PrinterCardView(client: client)
                        }
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var activeCount: Int { manager.clients.filter { $0.status.isPrinting }.count }
    private var hasPrinting: Bool { manager.clients.contains { $0.status.isPrinting } }
    private var hasPaused: Bool { manager.clients.contains { $0.status.state == .pause } }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 120, height: 120)
                Image(systemName: "printer")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                Text("プリンタが登録されていません")
                    .font(.title3.weight(.semibold))
                Text("設定からプリンタを追加するか、Bambu アカウントでログインすると\n登録済み機器が自動で一覧に表示されます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showingSettings = true
            } label: {
                Label("設定を開く", systemImage: "gearshape")
                    .padding(.horizontal, 10)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
