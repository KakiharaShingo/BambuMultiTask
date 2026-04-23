import Foundation
import AppKit
import Combine

/// BambuStudio の `libBambuSource.dylib` を動的ロードしてクラウドカメラ視聴に流用するためのブリッジ。
/// Phase 1 では存在確認 / dlopen 成功検証 / シンボル存在確認までを行い、実際のストリーム取得は Phase 2 で追加する。
@MainActor
final class BambuStudioBridge: ObservableObject {

    // MARK: - Types

    enum Status: Equatable {
        case unknown
        case searching
        case notFound
        case needsUserSelection(message: String)
        case detected(pluginPath: String, studioVersion: String?)
        case loaded(pluginPath: String, studioVersion: String?)
        case error(String)

        var isUsable: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    enum UseMode: String, CaseIterable, Identifiable {
        case auto, on, off
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto: return "自動"
            case .on: return "常に使う"
            case .off: return "使わない"
            }
        }
    }

    // MARK: - Published

    @Published private(set) var status: Status = .unknown
    @Published var mode: UseMode = .auto {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: modeKey) }
    }

    // MARK: - Private

    private var dylibHandle: UnsafeMutableRawPointer?
    private var securityScopedURL: URL?
    private let bookmarkKey = "bambuStudioPluginBookmark.v1"
    private let modeKey = "bambuStudioMode.v1"

    /// ライブラリ検索候補（優先度順）。
    private var knownPluginPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/BambuStudio/plugins/libBambuSource.dylib",
            "\(home)/Library/Application Support/BambuStudio/plugins/backup/libBambuSource.dylib",
            "/Applications/BambuStudio.app/Contents/Frameworks/libBambuSource.dylib",
            "/Applications/BambuStudio.app/Contents/MacOS/libBambuSource.dylib",
            "/Applications/BambuStudio.app/Contents/PlugIns/libBambuSource.dylib",
            "/Applications/Bambu Studio.app/Contents/Frameworks/libBambuSource.dylib",
        ]
    }

    /// プラグインのロードに必須のシンボル一覧（Phase 2 で叩くもの）。
    private let requiredSymbols = [
        "Bambu_Init", "Bambu_Deinit",
        "Bambu_Create", "Bambu_Destroy",
        "Bambu_Open", "Bambu_Close",
        "Bambu_StartStream", "Bambu_StartStreamEx",
        "Bambu_GetStreamCount", "Bambu_GetStreamInfo",
        "Bambu_ReadSample",
        "Bambu_GetLastErrorMsg"
    ]

    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.string(forKey: modeKey),
           let m = UseMode(rawValue: saved) {
            self.mode = m
        }
        restoreBookmark()
    }

    deinit {
        if let h = dylibHandle { dlclose(h) }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Public API (Phase 1)

    /// 起動時に呼ぶ。設定を尊重してロード/停止を決定する。
    func probe() {
        status = .searching
        if mode == .off {
            status = .unknown
            return
        }
        // 既存ブックマーク（ユーザー選択済み）があればそれを優先
        if let url = securityScopedURL {
            let dylib = url.appendingPathComponent("libBambuSource.dylib")
            if FileManager.default.fileExists(atPath: dylib.path) {
                attemptLoad(pluginPath: dylib.path)
                return
            }
        }
        // 既知パスを sandbox 内で順に fileExists チェック
        for path in knownPluginPaths {
            if FileManager.default.isReadableFile(atPath: path) {
                attemptLoad(pluginPath: path)
                return
            }
        }
        // 見つからない場合はユーザーに選択してもらう必要あり（sandbox 制約）
        status = .needsUserSelection(message: "BambuStudio プラグインフォルダを手動で選択してください")
    }

    /// NSOpenPanel で plugins フォルダを選ばせて security-scoped bookmark を保存。
    func selectPluginFolder() {
        let panel = NSOpenPanel()
        panel.title = "BambuStudio プラグインフォルダを選択"
        panel.message = "~/Library/Application Support/BambuStudio/plugins を選択してください"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let defaultPath = "\(NSHomeDirectory())/Library/Application Support/BambuStudio/plugins"
        if FileManager.default.fileExists(atPath: defaultPath) {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in self.applySelection(url) }
        }
    }

    /// Phase 1 完了後、Phase 2 から使う: 実際の関数ポインタを解決
    func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let h = dylibHandle else { return nil }
        return dlsym(h, name)
    }

    /// プラグインが存在するディレクトリ（.dylib の親）。ロード済みの場合のみ返す。
    var pluginsDirectory: String? {
        if case .loaded(let path, _) = status {
            return (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    var isEffectivelyEnabled: Bool {
        switch mode {
        case .off: return false
        case .on, .auto: return status.isUsable
        }
    }

    // MARK: - Internal flow

    private func applySelection(_ url: URL) {
        // 既存 security-scope を解放
        if let oldURL = securityScopedURL {
            oldURL.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            status = .error("ブックマーク保存失敗: \(error.localizedDescription)")
            return
        }
        if url.startAccessingSecurityScopedResource() {
            self.securityScopedURL = url
        }
        let dylib = url.appendingPathComponent("libBambuSource.dylib")
        if FileManager.default.fileExists(atPath: dylib.path) {
            attemptLoad(pluginPath: dylib.path)
        } else {
            status = .error("選択フォルダに libBambuSource.dylib が見つかりません")
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if url.startAccessingSecurityScopedResource() {
                self.securityScopedURL = url
            }
        } catch {
            NSLog("BambuStudioBridge: bookmark restore failed: \(error)")
        }
    }

    private func attemptLoad(pluginPath: String) {
        let studioVersion = detectStudioVersion()
        status = .detected(pluginPath: pluginPath, studioVersion: studioVersion)

        // dlopen 試行
        dlerror() // clear
        guard let handle = dlopen(pluginPath, RTLD_NOW | RTLD_LOCAL) else {
            let err = dlerror().flatMap { String(cString: $0) } ?? "unknown dlopen error"
            status = .error("dlopen 失敗: \(err)")
            return
        }
        // 必須シンボル検証
        var missing: [String] = []
        for sym in requiredSymbols {
            if dlsym(handle, sym) == nil {
                missing.append(sym)
            }
        }
        if !missing.isEmpty {
            dlclose(handle)
            status = .error("必須シンボルが欠落: \(missing.joined(separator: ", "))")
            return
        }
        // 既存ハンドルを解放
        if let old = dylibHandle { dlclose(old) }
        dylibHandle = handle
        status = .loaded(pluginPath: pluginPath, studioVersion: studioVersion)
        NSLog("BambuStudioBridge: loaded \(pluginPath) (studio \(studioVersion ?? "?"))")
    }

    private func detectStudioVersion() -> String? {
        for p in [
            "/Applications/BambuStudio.app/Contents/Info.plist",
            "/Applications/Bambu Studio.app/Contents/Info.plist"
        ] {
            if let dict = NSDictionary(contentsOfFile: p),
               let ver = dict["CFBundleShortVersionString"] as? String {
                return ver
            }
        }
        return nil
    }
}
