import Foundation
import AVFoundation
import CoreMedia
import Accelerate // vDSP

// MARK: - AudioCapture (R3): 録音→WAV書き出し→通知
// - 既定: AVAudioEngine（システム既定入力）
// - マイク指定: AVCaptureSession（UserDefaults "selected_microphone_unique_id" を採用）
// - 書き出し: リニアPCM 16-bit / Mono / 入力サンプルレート
// - 停止時: .audioFileReady を post（userInfo["url"] = 書き出しWAV URL）
final class AudioCapture: NSObject {

    // MARK: Singleton
    static let shared = AudioCapture()

    // MARK: Public Logs Tag
    private let tag = "[AudioCapture:R3]"

    // MARK: State
    private enum Backend {
        case engine           // AVAudioEngine（既定入力）
        case captureSession   // AVCaptureSession（特定デバイスを選択）
    }
    private var backend: Backend = .engine

    private var engine = AVAudioEngine()
    private var inputFormat: AVAudioFormat?
    private var engineTapInstalled = false

    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "sig.voicetodoclite.capture")

    // WAV writer
    private var wavWriter: WAVWriter?
    private var currentFileURL: URL?

    // MARK: Control

    /// 録音開始（保存先: AppのDocuments/tmp/rec_*.wav）
    func start() {
        stop() // 念のためクリーン

        // 出力先ファイル
        let tmp = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fn = String(format: "rec_%ld.wav", time(nil))
        let outURL = tmp.appendingPathComponent(fn)
        currentFileURL = outURL

        // バックエンド選択
        if let selectedID = UserDefaults.standard.string(forKey: "selected_microphone_unique_id"),
           !selectedID.isEmpty,
           AVCaptureDevice.devices(for: .audio).contains(where: { $0.uniqueID == selectedID }) {
            backend = .captureSession
        } else {
            backend = .engine
        }

        print("\(tag) [write] header placeholder 44B -> \(fn)")

        switch backend {
        case .engine:
            startEngineBackend(outURL: outURL)
        case .captureSession:
            startCaptureBackend(outURL: outURL)
        }
    }

    /// 録音停止（WAV finalize → .audioFileReady 通知）
    func stop() {
        switch backend {
        case .engine:
            if engineTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                engineTapInstalled = false
            }
            if engine.isRunning {
                engine.stop()
            }
        case .captureSession:
            captureSession?.stopRunning()
            captureSession = nil
        }

        // finalize WAV
        if let writer = wavWriter {
            let dataBytes = writer.finalize()
            let size = (try? FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            print("\(tag) ✅ finalized wav size=\(size) B (data=\(dataBytes) B)")
            print("\(tag) 🧾 recorded size=\(size) B")
            wavWriter = nil

            // 🔔 録音状態（停止）をブロードキャスト
            NotificationCenter.default.post(name: .init("audioCapture.state"), object: nil, userInfo: ["recording": false])

            // 送信
            NotificationCenter.default.post(name: .init("audioFileReady"),
                                            object: nil,
                                            userInfo: ["url": writer.fileURL])
            print("\(tag) 🛑 stop (post .audioFileReady)")
        }
    }

    // MARK: Backend: AVAudioEngine

    private func startEngineBackend(outURL: URL) {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        inputFormat = inFormat

        // WAV Writer: mono / 16bit / input sample rate
        let targetSampleRate = inFormat.sampleRate
        wavWriter = WAVWriter(fileURL: outURL,
                              sampleRate: targetSampleRate,
                              channels: 1,
                              bitsPerChannel: 16)

        do {
            // Install tap
            let bufCapacity: AVAudioFrameCount = 4096
            input.installTap(onBus: 0, bufferSize: bufCapacity, format: inFormat) { [weak self] buffer, _ in
                guard let self, let writer = self.wavWriter else { return }
                // downmix to mono & 16-bit
                let frames = Int(buffer.frameLength)
                let ch = Int(inFormat.channelCount)
                if let ptr = buffer.floatChannelData {
                    // mono mix
                    var mono = [Float](repeating: 0, count: frames)
                    for c in 0..<ch {
                        let src = ptr[c]
                        vDSP_vadd(mono, 1, src, 1, &mono, 1, vDSP_Length(frames))
                    }
                    if ch > 1 {
                        var scale = 1.0 / Float(ch)
                        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
                    }
                    writer.appendFloatsAsPCM16(mono)
                } else if let int16 = buffer.int16ChannelData {
                    // int16 → mono mix（単純平均）
                    let frames = Int(buffer.frameLength)
                    let ch = Int(inFormat.channelCount)
                    var mono16 = [Int16](repeating: 0, count: frames)
                    if ch == 1 {
                        mono16.withUnsafeMutableBufferPointer { dst in
                            dst.baseAddress!.assign(from: int16[0], count: frames)
                        }
                    } else {
                        for i in 0..<frames {
                            var acc: Int = 0
                            for c in 0..<ch { acc += Int(int16[c][i]) }
                            mono16[i] = Int16(max(-32768, min(32767, acc / ch)))
                        }
                    }
                    writer.appendPCM16(mono16)
                }
            }
            engineTapInstalled = true

            try engine.start()
            print("\(tag) engine started, in=\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch f=\(inFormat.commonFormat.rawValue)")
            // 🔔 録音状態（開始）をブロードキャスト
            NotificationCenter.default.post(name: .init("audioCapture.state"), object: nil, userInfo: ["recording": true])
            print("\(tag) 🎙️ start → \(outURL.lastPathComponent)")
        } catch {
            print("\(tag) ❌ engine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: Backend: AVCaptureSession（マイク指定・フォーマット強制）

    private func startCaptureBackend(outURL: URL) {
        guard let selectedID = UserDefaults.standard.string(forKey: "selected_microphone_unique_id"),
              let device = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == selectedID }) else {
            print("\(tag) ⚠️ selected mic not found, fallback to engine")
            backend = .engine
            startEngineBackend(outURL: outURL)
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureAudioDataOutput()

            // ★ Float32 / 1ch / Interleaved を強制
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: 0,
                AVNumberOfChannelsKey: 1
            ]

            output.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(output) { session.addOutput(output) }

            session.commitConfiguration()
            captureSession = session

            // 出力フォーマットは最初のサンプルで確定
            wavWriter = WAVWriter(fileURL: outURL,
                                  sampleRate: 0, // 初回バッファで上書き
                                  channels: 1,
                                  bitsPerChannel: 16)

            session.startRunning()
            print("\(tag) capture started (\(device.localizedName)) → \(outURL.lastPathComponent)")
            // 🔔 録音状態（開始）をブロードキャスト
            NotificationCenter.default.post(name: .init("audioCapture.state"), object: nil, userInfo: ["recording": true])
        } catch {
            print("\(tag) ❌ capture start failed: \(error.localizedDescription)")
            // フォールバック
            backend = .engine
            startEngineBackend(outURL: outURL)
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let writer = self.wavWriter else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = Int(asbd.pointee.mChannelsPerFrame)

        // 初回で sampleRate 未設定なら確定（ヘッダ更新は finalize 時に反映）
        if writer.sampleRate == 0 {
            writer.sampleRate = sampleRate
            print("[AudioCapture:R3] engine started, in=\(sampleRate)Hz/\(channels)ch f=1")
            if let url = currentFileURL {
                print("[AudioCapture:R3] 🎙️ start → \(url.lastPathComponent)")
            }
        }

        // PCM データ
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer) != noErr {
            return
        }
        guard let base = dataPointer else { return }

        // audioSettings で Float32 / 1ch / Interleaved を強制している前提
        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame) // Float32 * 1ch = 4 bytes
        let frames = max(0, length / max(1, bytesPerFrame))
        let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(base))

        // そのままPCM16へ
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.assign(from: floatPtr, count: frames)
        }
        writer.appendFloatsAsPCM16(mono)
    }
}

// MARK: - WAV Writer（シンプル）

private final class WAVWriter {
    let fileURL: URL
    var sampleRate: Double   // 初回 0 の場合は最初のバッファで確定
    let channels: Int
    let bitsPerChannel: Int

    private var handle: FileHandle?
    private var bytesWritten: Int = 0

    init(fileURL: URL, sampleRate: Double, channels: Int, bitsPerChannel: Int) {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: fileURL)
            writeHeaderPlaceholder()
        } catch {
            print("[AudioCapture:R3] ❌ open wav failed: \(error.localizedDescription)")
        }
    }

    func appendFloatsAsPCM16(_ floats: [Float]) {
        // クリップ＆量子化
        var clipped = floats
        var maxV: Float = 1.0
        var minV: Float = -1.0
        vDSP_vclip(clipped, 1, &minV, &maxV, &clipped, 1, vDSP_Length(clipped.count))
        var scale: Float = Float(Int16.max)
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(clipped.count))
        var s16 = [Int16](repeating: 0, count: clipped.count)
        vDSP_vfix16(clipped, 1, &s16, 1, vDSP_Length(clipped.count))
        appendPCM16(s16)
    }

    func appendPCM16(_ data: [Int16]) {
        guard let handle else { return }
        let bytes = data.withUnsafeBytes { Data($0) }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            bytesWritten += bytes.count
        } catch {
            print("[AudioCapture:R3] ❌ write failed: \(error.localizedDescription)")
        }
    }

    func finalize() -> Int {
        guard let handle else { return 0 }
        do {
            // ヘッダ更新
            try handle.seek(toOffset: 0)
            let header = makeWAVHeader(totalPCMBytes: bytesWritten)
            try handle.write(contentsOf: header)
            try handle.close()
        } catch {
            print("[AudioCapture:R3] ❌ finalize failed: \(error.localizedDescription)")
        }
        return bytesWritten
    }

    // MARK: WAV Header

    private func writeHeaderPlaceholder() {
        guard let handle else { return }
        let header = Data(repeating: 0, count: 44)
        do {
            try handle.write(contentsOf: header)
        } catch {
            print("[AudioCapture:R3] ❌ header write failed: \(error.localizedDescription)")
        }
    }

    private func makeWAVHeader(totalPCMBytes: Int) -> Data {
        let sr = UInt32(max(1, Int(sampleRate)))
        let ch = UInt16(channels)
        let bpc = UInt16(bitsPerChannel)
        let blockAlign = UInt16((bitsPerChannel / 8) * channels)
        let byteRate = UInt32(Int(sr) * Int(blockAlign))

        var data = Data()

        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func append(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }

        append("RIFF")
        append(UInt32(36 + totalPCMBytes))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))                  // fmt chunk size
        append(UInt16(1))                   // PCM
        append(ch)                          // channels
        append(sr)                          // sample rate
        append(byteRate)                    // byte rate
        append(blockAlign)                  // block align
        append(bpc)                         // bits per sample
        append("data")
        append(UInt32(totalPCMBytes))       // data size

        return data
    }
}
