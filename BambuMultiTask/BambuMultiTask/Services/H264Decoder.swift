import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit

/// シンプルな H.264 Annex-B → NSImage デコーダ。
/// SPS/PPS が届くのを待ち、フォーマット記述子を作ってから VTDecompressionSession で各フレームを NSImage に変換する。
final class H264Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    /// 出力 NSImage のコールバック（バックグラウンドスレッドで呼ばれる）
    var onFrame: ((NSImage) -> Void)?

    deinit {
        invalidate()
    }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        formatDesc = nil
        sps = nil
        pps = nil
    }

    /// Annex-B バイトストリーム(1つのサンプル分)を投入。NAL 単位で分割して処理。
    func submit(data: Data) {
        let nals = splitAnnexB(data)
        var avccFrames: [Data] = []
        for nal in nals {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            switch nalType {
            case 7: // SPS
                sps = nal
                tryBuildFormatDescription()
            case 8: // PPS
                pps = nal
                tryBuildFormatDescription()
            case 5, 1: // IDR / non-IDR slice
                // AVCC 形式 (4 byte length prefix + NAL body) に変換して蓄積
                var avcc = Data()
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(nal)
                avccFrames.append(avcc)
            default:
                break
            }
        }
        for avcc in avccFrames {
            decodeAVCC(frame: avcc)
        }
    }

    // MARK: - Annex-B parsing

    /// 0x00 00 00 01 / 0x00 00 01 の start code で分割
    private func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        var startIndices: [Int] = []
        let count = data.count
        var i = 0
        while i + 2 < count {
            if data[i] == 0 && data[i+1] == 0 {
                if data[i+2] == 1 {
                    startIndices.append(i + 3)
                    i += 3
                    continue
                }
                if i + 3 < count && data[i+2] == 0 && data[i+3] == 1 {
                    startIndices.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }
        for (idx, start) in startIndices.enumerated() {
            let end = (idx + 1 < startIndices.count)
                ? findStartCodeEnd(data: data, searchFrom: startIndices[idx + 1]) ?? startIndices[idx + 1]
                : data.count
            if end > start {
                // 次の start code の前のゼロバイト群を除外
                var actualEnd = end
                while actualEnd > start + 1 && data[actualEnd - 1] == 0 {
                    actualEnd -= 1
                }
                nals.append(data.subdata(in: start..<actualEnd))
            }
        }
        return nals
    }

    private func findStartCodeEnd(data: Data, searchFrom: Int) -> Int? {
        // start code の手前位置を返す（ゼロゼロ[ゼロ]1 の先頭）
        if searchFrom >= 3 {
            if data[searchFrom - 4] == 0 && data[searchFrom - 3] == 0 && data[searchFrom - 2] == 0 && data[searchFrom - 1] == 1 {
                return searchFrom - 4
            }
            if data[searchFrom - 3] == 0 && data[searchFrom - 2] == 0 && data[searchFrom - 1] == 1 {
                return searchFrom - 3
            }
        }
        return nil
    }

    // MARK: - Format description / session

    private func tryBuildFormatDescription() {
        guard let sps, let pps, session == nil else { return }

        var fd: CMVideoFormatDescription?
        let result: OSStatus = sps.withUnsafeBytes { spsPtr -> OSStatus in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                let spsBase = spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsBase = ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let paramSets: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let paramSizes = [sps.count, pps.count]
                return paramSets.withUnsafeBufferPointer { psPtr in
                    paramSizes.withUnsafeBufferPointer { szPtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: psPtr.baseAddress!,
                            parameterSetSizes: szPtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd
                        )
                    }
                }
            }
        }
        guard result == noErr, let format = fd else {
            NSLog("H264Decoder: CreateFormatDescription failed: \(result)")
            return
        }
        formatDesc = format

        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        if status == noErr, let s = newSession {
            session = s
            NSLog("H264Decoder: decoder session created")
        } else {
            NSLog("H264Decoder: session create failed: \(status)")
        }
    }

    // MARK: - Decode

    private func decodeAVCC(frame: Data) {
        guard let session, let formatDesc else { return }

        var blockBuffer: CMBlockBuffer?
        let dataCopy = UnsafeMutableRawPointer.allocate(byteCount: frame.count, alignment: 1)
        _ = frame.withUnsafeBytes { src in
            memcpy(dataCopy, src.baseAddress, frame.count)
        }
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataCopy,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == noErr, let bb = blockBuffer else {
            NSLog("H264Decoder: CMBlockBuffer create failed: \(status1)")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frame.count
        let status2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status2 == noErr, let sb = sampleBuffer else {
            NSLog("H264Decoder: CMSampleBuffer create failed: \(status2)")
            return
        }

        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            infoFlagsOut: &flagsOut,
            outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let buffer = imageBuffer else { return }
                if let img = NSImage.fromPixelBuffer(buffer) {
                    self?.onFrame?(img)
                }
            }
        )
        if decodeStatus != noErr {
            // -12909 (codecBadDataErr) などはデコード失敗だが継続可能なので無視
        }
    }
}

extension NSImage {
    static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }
}
