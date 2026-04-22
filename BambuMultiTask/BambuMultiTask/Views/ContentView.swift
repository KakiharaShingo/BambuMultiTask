import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var manager: PrinterManager
    @EnvironmentObject var cloud: BambuCloudSession
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.clients.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(manager.clients, id: \.printer.id) { client in
                            PrinterCardView(client: client)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
                .environmentObject(settings)
                .environmentObject(cloud)
                .environmentObject(manager)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "printer.fill.and.paper.fill")
                .font(.title2)
            Text("Bambu MultiTask")
                .font(.title2.bold())
            Spacer()
            Button {
                manager.refreshAll()
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            Button {
                showingSettings = true
            } label: {
                Label("設定", systemImage: "gear")
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "printer")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("プリンタがまだ登録されていません")
                .font(.headline)
            Text("設定からプリンタを追加するか、Bambu アカウントでログインしてください")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingSettings = true
            } label: {
                Label("設定を開く", systemImage: "gear")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
