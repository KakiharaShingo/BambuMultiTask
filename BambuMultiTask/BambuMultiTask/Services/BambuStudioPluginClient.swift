import Foundation
import AppKit
import VideoToolbox
import CoreMedia
import os

// MARK: - ABI C types

/// BambuStudio 公式ヘッダ (BambuTunnel.h) の定義に準拠:
///   typedef struct __Bambu_Sample {
///       int itrack;
///       int size;
///       int flags;
///       unsigned char const * buffer;   // 8-byte aligned (4 bytes padding)
///       unsigned long long decode_time;
///   } Bambu_Sample;
struct Bambu_Sample {
    var itrack: Int32 = 0
    var size: Int32 = 0
    var flags: Int32 = 0
    var _pad: Int32 = 0  // 8-byte alignment for buffer pointer
    var buffer: UnsafeMutablePointer<UInt8>? = nil
    var decode_time: UInt64 = 0
}

struct Bambu_StreamInfo_Video {
    var width: Int32 = 0
    var height: Int32 = 0
    var frame_rate: Int32 = 0
}

struct Bambu_StreamInfo {
    var type: Int32 = 0
    var sub_type: Int32 = 0
    var v0: Int32 = 0        // union first dword (video.width / audio.sample_rate)
    var v1: Int32 = 0
    var v2: Int32 = 0
    var format_type: Int32 = 0
    var format_size: Int32 = 0
    var max_frame_size: Int32 = 0
    var format_buffer: UnsafeMutablePointer<UInt8>? = nil
}

typealias Bambu_Tunnel = OpaquePointer

// @convention(c) で Obj-C 表現可能にするため、構造体ポインタは UnsafeMutableRawPointer を使う。
private typealias BambuInit              = @convention(c) () -> Int32
private typealias BambuDeinit            = @convention(c) () -> Void
private typealias BambuCreate            = @convention(c) (UnsafeMutablePointer<Bambu_Tunnel?>, UnsafePointer<CChar>) -> Int32
private typealias BambuDestroy           = @convention(c) (Bambu_Tunnel) -> Void
private typealias BambuOpen              = @convention(c) (Bambu_Tunnel) -> Int32
private typealias BambuClose             = @convention(c) (Bambu_Tunnel) -> Void
private typealias BambuStartStream       = @convention(c) (Bambu_Tunnel, Int32) -> Int32
private typealias BambuStartStreamEx     = @convention(c) (Bambu_Tunnel, Int32) -> Int32
private typealias BambuGetStreamCount    = @convention(c) (Bambu_Tunnel) -> Int32
private typealias BambuGetStreamInfo     = @convention(c) (Bambu_Tunnel, Int32, UnsafeMutableRawPointer) -> Int32
private typealias BambuReadSample        = @convention(c) (Bambu_Tunnel, UnsafeMutableRawPointer) -> Int32
private typealias BambuGetLastErrorMsg   = @convention(c) () -> UnsafePointer<CChar>?
// 公式ヘッダ: typedef void (*Logger)(void* context, int level, tchar const* msg);
// macOS では tchar = char
private typealias BambuLogCallback       = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void
// 公式: void Bambu_SetLogger(Bambu_Tunnel tunnel, Logger logger, void* context);
private typealias BambuSetLogger         = @convention(c) (Bambu_Tunnel, BambuLogCallback?, UnsafeMutableRawPointer?) -> Void

/// プラグイン内部ログを捕捉するコールバック。
/// level 1=error, 2=warn, 3=info/debug の想定。debug は情報量が多すぎるのでデフォルト抑制。
private let bambuLogCallback: BambuLogCallback = { _, level, cstr in
    guard let cstr else { return }
    // level 3 (debug) の would_block / read_sample ログは抑制
    if level >= 3 { return }
    let msg = String(cString: cstr)
    NSLog("%@", "BambuPluginLog[\(level)]: \(msg)")
}

/// スレッド間で共有する停止フラグ。
private final class StopFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    func stop() { lock.withLock { $0 = true } }
    func reset() { lock.withLock { $0 = false } }
    var isStopped: Bool { lock.withLock { $0 } }
}

/// BambuStudio プラグイン経由でカメラストリームを受信するクライアント。
@MainActor
final class BambuStudioPluginClient {
    private let bridge: BambuStudioBridge
    private let stopFlag = StopFlag()
    private var workerThread: Thread?
    private var onFrame: ((NSImage) -> Void)?
    private var onConnected: (() -> Void)?
    private var onError: ((String) -> Void)?

    init(bridge: BambuStudioBridge) {
        self.bridge = bridge
    }

    func startWithURL(
        _ url: String,
        label: String,
        onConnected: @escaping () -> Void,
        onFrame: @escaping (NSImage) -> Void,
        onError: @escaping (String) -> Void
    ) {
        stop()
        self.onFrame = onFrame
        self.onConnected = onConnected
        self.onError = onError
        self.stopFlag.reset()

        guard let initFn: BambuInit = resolve("Bambu_Init"),
              let createFn: BambuCreate = resolve("Bambu_Create"),
              let openFn: BambuOpen = resolve("Bambu_Open"),
              let startStreamFn: BambuStartStream = resolve("Bambu_StartStream"),
              let getCountFn: BambuGetStreamCount = resolve("Bambu_GetStreamCount"),
              let getInfoFn: BambuGetStreamInfo = resolve("Bambu_GetStreamInfo"),
              let readFn: BambuReadSample = resolve("Bambu_ReadSample"),
              let closeFn: BambuClose = resolve("Bambu_Close"),
              let destroyFn: BambuDestroy = resolve("Bambu_Destroy"),
              let lastErrFn: BambuGetLastErrorMsg = resolve("Bambu_GetLastErrorMsg")
        else {
            onError("BambuStudio プラグインのシンボル解決に失敗")
            return
        }
        // Ex版は任意（新機種(P2S 等)で必要）
        let startStreamExFn: BambuStartStreamEx? = resolve("Bambu_StartStreamEx")
        // Logger (オプショナル)
        let setLoggerFn: BambuSetLogger? = resolve("Bambu_SetLogger")

        NSLog("BambuStudioPluginClient[\(label)]: starting url=\(url)")

        // UI callbacks を Sendable にラップ
        let connectedCb = onConnected
        let frameCb = onFrame
        let errorCb = onError
        let flag = stopFlag

        let thread = Thread {
            Self.runLoop(
                url: url, flag: flag,
                initFn: initFn, createFn: createFn, openFn: openFn,
                startStreamFn: startStreamFn, startStreamExFn: startStreamExFn,
                getCountFn: getCountFn,
                getInfoFn: getInfoFn, readFn: readFn,
                closeFn: closeFn, destroyFn: destroyFn,
                lastErrFn: lastErrFn, setLoggerFn: setLoggerFn,
                onConnected: connectedCb, onFrame: frameCb, onError: errorCb
            )
        }
        thread.name = "BambuStudioPluginClient.\(label)"
        thread.qualityOfService = QualityOfService.userInitiated
        self.workerThread = thread
        thread.start()
    }

    func stop() {
        stopFlag.stop()
        workerThread = nil
    }

    deinit {
        stopFlag.stop()
    }

    private func resolve<T>(_ name: String) -> T? {
        guard let ptr = bridge.symbol(name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    // MARK: - Worker

    nonisolated private static func runLoop(
        url: String,
        flag: StopFlag,
        initFn: BambuInit,
        createFn: BambuCreate,
        openFn: BambuOpen,
        startStreamFn: BambuStartStream,
        startStreamExFn: BambuStartStreamEx?,
        getCountFn: BambuGetStreamCount,
        getInfoFn: BambuGetStreamInfo,
        readFn: BambuReadSample,
        closeFn: BambuClose,
        destroyFn: BambuDestroy,
        lastErrFn: BambuGetLastErrorMsg,
        setLoggerFn: BambuSetLogger?,
        onConnected: @escaping () -> Void,
        onFrame: @escaping (NSImage) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let initResult = initFn()
        NSLog("%@", "BambuStudioPlugin: Bambu_Init -> \(initResult)")

        var tunnelRef: Bambu_Tunnel? = nil
        let createResult = url.withCString { createFn(&tunnelRef, $0) }
        if createResult != 0 || tunnelRef == nil {
            let em = lastErrorMessage(lastErrFn) ?? "(no error msg)"
            DispatchQueue.main.async { onError("Bambu_Create failed code=\(createResult) err=\(em)") }
            return
        }
        guard let tun = tunnelRef else { return }

        // tunnel ごとに logger を設定してプラグイン内部ログを捕捉
        if let setLoggerFn {
            setLoggerFn(tun, bambuLogCallback, nil)
            NSLog("%@", "BambuStudioPlugin: Bambu_SetLogger installed for tunnel")
        }

        defer {
            closeFn(tun)
            destroyFn(tun)
        }

        let openResult = openFn(tun)
        if openResult != 0 {
            let em = lastErrorMessage(lastErrFn) ?? "(no error msg)"
            DispatchQueue.main.async { onError("Bambu_Open failed code=\(openResult) err=\(em)") }
            return
        }
        NSLog("%@", "BambuStudioPlugin: Bambu_Open OK")

        // Bambu_StartStream は非同期で、返り値 2 = "would block" で再試行。
        // 0 = 成功、1 = stream_end、2 = would_block、3 = buffer_limit、その他 = エラー。
        // P2S 等の新機種では Bambu_StartStream が -1 を返すので Bambu_StartStreamEx にフォールバック。
        func tryStart(_ useEx: Bool) -> Int32 {
            var result: Int32 = 2
            let deadline = Date().addingTimeInterval(10)
            while result == 2 && Date() < deadline && !flag.isStopped {
                if useEx, let ex = startStreamExFn {
                    result = ex(tun, 0)  // type=0 (video)
                } else {
                    result = startStreamFn(tun, 1)  // video=true
                }
                if result == 2 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            return result
        }
        var streamResult = tryStart(false)
        // rc=2 は would_block タイムアウト (retry deadline 到達)。fallback しても同じ。
        // 真のエラー (-1 等) の場合のみ Ex 版にフォールバック。
        if streamResult != 0 && streamResult != 2 && startStreamExFn != nil {
            NSLog("%@", "BambuStudioPlugin: Bambu_StartStream rc=\(streamResult), falling back to Bambu_StartStreamEx")
            streamResult = tryStart(true)
        }
        if streamResult != 0 {
            let em = lastErrorMessage(lastErrFn) ?? "(no error msg)"
            let msg: String
            switch streamResult {
            case 2:
                msg = "カメラ映像が届きません（カメラハードウェア故障または機能無効の可能性）"
            case -1:
                // printer 側が start_stream 直後に接続を切断。
                // MQTT は通っているので access code は合っている前提。
                // P2S 等の新機種は LAN モードでカメラ提供していない機種がある。
                msg = "LAN モードでカメラストリームに対応していない機種の可能性があります（P2S 等はクラウド/Bambu Studio 経由でのみ視聴可）"
            default:
                msg = "カメラストリーム開始エラー code=\(streamResult) err=\(em)"
            }
            DispatchQueue.main.async { onError(msg) }
            return
        }
        NSLog("%@", "BambuStudioPlugin: Bambu_StartStream OK")

        // 解像度・フォーマット取得
        let streamCount = getCountFn(tun)
        var subType: Int32 = 0
        var streamInfo = Bambu_StreamInfo()
        for i in 0..<streamCount {
            var info = Bambu_StreamInfo()
            let r = withUnsafeMutablePointer(to: &info) { ptr in
                getInfoFn(tun, i, UnsafeMutableRawPointer(ptr))
            }
            if r == 0, info.type == 1 {
                streamInfo = info
                subType = info.sub_type
                NSLog("BambuStudioPlugin: video stream idx=\(i) sub_type=\(info.sub_type) size=\(info.v0)x\(info.v1) format_type=\(info.format_type)")
                break
            }
        }
        _ = streamInfo

        DispatchQueue.main.async { onConnected() }

        // H.264 用のデコーダ（sub_type==1 の場合のみ使う）
        let h264 = H264Decoder()
        h264.onFrame = { img in
            DispatchQueue.main.async { onFrame(img) }
        }

        var sample = Bambu_Sample()
        var consecutiveErrors = 0
        var frameCounter = 0
        while !flag.isStopped {
            let r = withUnsafeMutablePointer(to: &sample) { ptr in
                readFn(tun, UnsafeMutableRawPointer(ptr))
            }
            if r == 2 {
                // would block - new frame not yet ready
                Thread.sleep(forTimeInterval: 0.03)
                continue
            }
            if r != 0 {
                consecutiveErrors += 1
                if consecutiveErrors > 50 {
                    let em = lastErrorMessage(lastErrFn) ?? "(no error msg)"
                    DispatchQueue.main.async { onError("Bambu_ReadSample 連続失敗 code=\(r) err=\(em)") }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            consecutiveErrors = 0
            guard let buf = sample.buffer, sample.size > 0 else { continue }
            let data = Data(bytes: buf, count: Int(sample.size))

            frameCounter += 1
            if frameCounter <= 3 || frameCounter % 60 == 0 {
                let prefix = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                NSLog("BambuStudioPlugin: frame #\(frameCounter) subType=\(subType) size=\(data.count) head=\(prefix)")
            }

            // sub_type==1 は H.264、それ以外は JPEG を想定
            if subType == 1 {
                h264.submit(data: data)
            } else if let img = NSImage(data: data) {
                DispatchQueue.main.async { onFrame(img) }
            } else {
                // JPEG デコード失敗 → H.264 として再試行
                h264.submit(data: data)
            }
        }
        h264.invalidate()
    }

    nonisolated private static func lastErrorMessage(_ fn: BambuGetLastErrorMsg) -> String? {
        guard let ptr = fn() else { return nil }
        return String(cString: ptr)
    }
}
