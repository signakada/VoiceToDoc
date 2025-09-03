import Foundation
import WhisperKit
import UniformTypeIdentifiers


private func resolveStorageBaseURLFromBookmark(data: Data?) -> (base: URL?, stopAccess: (() -> Void)?) {
    guard let data = data else { return (nil, nil) }
    var isStale = false
    do {
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        var didStart = false
        if url.startAccessingSecurityScopedResource() { didStart = true }
        let stop: (() -> Void)? = didStart ? { url.stopAccessingSecurityScopedResource() } : nil
        return (url, stop)
    } catch {
        print("[WK] storage bookmark resolve failed: \(error.localizedDescription)")
    }
    return (nil, nil)
}

final class WhisperKitTranscriber: Transcriber {
    
    // MARK: - State
    private var wk: WhisperKit?
    private var currentModelId: String = ""
    private var currentLanguage: String = "auto"

    // 起動時に一度だけパージマネージャを開始
    init() {
        _ = PurgeOnQuitManager.start()
    }
    
    // MARK: - Transcriber protocol
    func prewarmIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            if self.wk == nil {
                do {
                    self.wk = try await WhisperKit()
                    print("🟢 [WK] ready (lazy init)")
                } catch {
                    print("[WK] ❌ prewarm failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        // WhisperKit側にキャンセルAPIがあればここで呼ぶ。現状は no-op。
    }

    func transcribeFile(
            at url: URL,
            language: String,
            storageBookmarkData: Data?
        ) async throws -> String {
            // --- 事前チェック ---
            let path = url.path
            let exists = FileManager.default.fileExists(atPath: path)
            let size   = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
            print("[WK] ▶️ transcribe: exists=\(exists) size=\(size) path=\(path)")
            guard exists, size > 44 else {
                throw NSError(domain: "WhisperKitTranscriber",
                              code: -10,
                              userInfo: [NSLocalizedDescriptionKey: "入力ファイルが不正です（存在しない/サイズが小さすぎる）"])
            }

            // --- ファイルをセッションフォルダへ移動 ---
            let (storageBase, stopAccess) = resolveStorageBaseURLFromBookmark(data: storageBookmarkData)
            defer { stopAccess?() }
            
            let resolvedBaseURL = storageBase ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            
            let fm = FileManager.default
            let baseFolder = resolvedBaseURL.appendingPathComponent("音声カルテ", isDirectory: true)
            if !fm.fileExists(atPath: baseFolder.path) {
                try? fm.createDirectory(at: baseFolder, withIntermediateDirectories: true)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let sessionName = formatter.string(from: Date())
            let session = baseFolder.appendingPathComponent(sessionName, isDirectory: true)
            if !fm.fileExists(atPath: session.path) {
                try? fm.createDirectory(at: session, withIntermediateDirectories: true)
            }
            let finalURL = session.appendingPathComponent(url.lastPathComponent)

            var didMove = false
            do {
                try fm.moveItem(at: url, to: finalURL)
                didMove = true
            } catch {
                // move failed, try copy
                do {
                    try fm.copyItem(at: url, to: finalURL)
                    didMove = true
                } catch {
                    print("[WK] ❌ move/copy failed: \(error.localizedDescription)")
                    throw NSError(domain: "WhisperKitTranscriber",
                                  code: -11,
                                  userInfo: [NSLocalizedDescriptionKey: "ファイルの移動/コピーに失敗しました"])
                }
            }
            print("[WK] 📂 audio file prepared at: \(finalURL.path)")
            
            // セッションフォルダ通知をメインスレッドで送信
            await MainActor.run {
                NotificationCenter.default.post(name: .init("sessionFolderReady"), object: nil, userInfo: ["url": session])
            }

            // --- セッション準備（遅延初期化 & 設定ログ）---
            try await ensureSessionForCurrentDefaults()

            // --- 言語解決（引数優先、空/autoはUserDefaults）---
            let udLang = (UserDefaults.standard.string(forKey: "whisper_force_language") ?? "auto")
            let langKey = language.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedLang = (langKey.isEmpty || langKey.lowercased() == "auto") ? udLang : langKey

            guard let wk else {
                throw NSError(domain: "WhisperKitTranscriber",
                              code: -20,
                              userInfo: [NSLocalizedDescriptionKey: "WhisperKit の初期化に失敗しました"])
            }

            do {
                // 戻り値は [TranscriptionResult]
                let opts = DecodingOptions(language: resolvedLang)
                let results = try await wk.transcribe(audioPath: finalURL.path, decodeOptions: opts)

                // 各要素の text を連結
                let text = results.map { $0.text }.joined()

                print("[WK] ✅ decoded: \(text.count) chars")
                
                // ファイルに保存（バックグラウンドで実行可能）
                let transcriptionURL = session.appendingPathComponent("transcription.txt")
                try text.data(using: .utf8)?.write(to: transcriptionURL, options: .atomic)
                print("[WK] 📝 saved transcription to \(transcriptionURL.path)")

                return text // 文字起こし結果を返す
            } catch {
                print("[WK] ❌ error: \(error.localizedDescription)")
                throw error
            }
        }

    // MARK: - Settings / Session
    private func ensureSessionForCurrentDefaults() async throws {
        let ud = UserDefaults.standard
        let desiredModel = (ud.string(forKey: "whisper_model_preference") ?? "large-v3-turbo")
        let desiredLang  = (ud.string(forKey: "whisper_force_language") ?? "auto")

        if currentModelId != desiredModel || currentLanguage != desiredLang {
            print("🔄 [WK] defaults changed → model: \(currentModelId) → \(desiredModel), lang: \(currentLanguage) → \(desiredLang)")
            // 将来: モデル切替の実装フック（例）
            // try await wk?.loadModel(id: desiredModel)
            currentModelId = desiredModel
            currentLanguage = desiredLang
        }

        if wk == nil {
            wk = try await WhisperKit()
            print("🟢 [WK] ready (lazy init)")
        }
    }
}

