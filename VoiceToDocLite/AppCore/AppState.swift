import Foundation
import Combine
import AppKit

/// R2: 録音完了通知 → 転写起動の起点を一本化
@MainActor
final class AppState: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var lastOutput: String = ""
    @Published var lastErrorMessage: String = ""
    // 最後に扱った音声ファイルと、そのセッションフォルダ（Tab1/2/3で共通利用）
    @Published var lastAudioURL: URL?
    @Published var lastSessionFolder: URL?
    // 【追加】最後に生成された要約テキスト
    @Published var lastSummary: String = ""

    private var cancellables = Set<AnyCancellable>()
    private let transcriber: Transcriber
    private let settings: SettingsStore // SettingsStoreをプロパティとして保持

    init(transcriber: Transcriber, settings: SettingsStore) { // initでSettingsStoreを受け取る
        self.transcriber = transcriber
        self.settings = settings // プロパティに代入
        
        NotificationCenter.default.publisher(for: Notification.Name("audioFileReady"))
            // メインスレッドでUI状態を更新し、その後の重い処理は別スレッドにディスパッチ
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                guard let url = note.userInfo?["url"] as? URL else {
                    print("[AppState] ⚠️ audioFileReady に URL が含まれていません")
                    return
                }
                self.lastAudioURL = url
                // 設定のブックマークデータを取得して渡す
                let storageBookmarkData = self.settings.storageBaseBookmark
                self.startTranscriptionAndSummarization(for: url, storageBookmarkData: storageBookmarkData)
            }
            .store(in: &cancellables)
        // Transcriber 側で確定したセッションフォルダ（~/Documents/音声カルテ/日時）を反映
        NotificationCenter.default.publisher(for: .init("sessionFolderReady"))
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                guard let url = note.userInfo?["url"] as? URL else { return }
                self.lastSessionFolder = url
                // 直前のファイル名が分かる場合は移動先のフルパスに更新
                if let name = self.lastAudioURL?.lastPathComponent {
                    self.lastAudioURL = url.appendingPathComponent(name)
                }
                print("[AppState] 📁 session folder = \(url.path)")
            }
            .store(in: &cancellables)
    }

    private func startTranscriptionAndSummarization(for url: URL, storageBookmarkData: Data?) {
        // メインスレッドで状態を「開始済み」に設定
        isBusy = true
        lastErrorMessage = ""

        print("[AppState] 🚀 転写開始 → \(url.lastPathComponent)")

        // バックグラウンドで文字起こしと要約を実行
        Task {
            do {
                // 文字起こし結果を直接取得
                let transcriptionText = try await self.transcriber.transcribeFile(at: url, language: "ja", storageBookmarkData: storageBookmarkData)
                
                let processedText = TextPostProcessor.process(transcriptionText, language: "ja")

                // メインスレッドでlastOutputを更新し、完了を通知
                await MainActor.run {
                    self.lastOutput = processedText
                    self.isBusy = false
                    print("[AppState] ✅ 転写完了: decoded=\(processedText.count) chars")
                }
                
                // 文字起こし完了後、要約処理を開始
                NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "summarizing"])
                
                let sys = self.settings.resolveSystemPromptForSelectedPreset()
                let summary = try await SummarizerService.shared.summarize(processedText, systemPrompt: sys)

                // メインスレッドで要約結果を更新し、クリップボードにコピー
                await MainActor.run {
                    self.lastErrorMessage = ""
                    
                    NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "done"])
                    
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    #endif
                    
                    NotificationCenter.default.post(name: .init("summaryReady"), object: nil, userInfo: ["text": summary])
                    // 【修正】要約結果をAppStateに保存
                    self.lastSummary = summary
                    
                    // === 要約結果をファイルに保存 ===
                    if let folder = self.lastSessionFolder {
                        // セキュリティスコープアクセスを再開
                        let (storageBase, stopAccess) = self.resolveStorageBaseURLFromBookmark()
                        defer { stopAccess?() }
                        
                        let fileURL = folder.appendingPathComponent("summary.txt")
                        do {
                            try summary.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                            print("[AppState] 📝 saved summary to \(fileURL.path)")
                        } catch {
                            print("[AppState] ❌ failed to save summary: \(error.localizedDescription)")
                        }
                    }
                    
                    print("[AppState] ✅ 要約完了 & クリップボードにコピー")
                }

            } catch {
                // エラー発生時、メインスレッドで状態を更新
                await MainActor.run {
                    self.lastErrorMessage = error.localizedDescription
                    self.isBusy = false
                    print("[AppState] ❌ 転写/要約失敗: \(error.localizedDescription)")
                    NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "idle"])
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// セキュリティスコープ付きブックマークを解決してアクセス権を開始
    private func resolveStorageBaseURLFromBookmark() -> (base: URL?, stopAccess: (() -> Void)?) {
        guard let data = settings.storageBaseBookmark else { return (nil, nil) }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            var didStart = false
            if url.startAccessingSecurityScopedResource() { didStart = true }
            let stop: (() -> Void)? = didStart ? { url.stopAccessingSecurityScopedResource() } : nil
            return (url, stop)
        } catch {
            print("[AppState] storage bookmark resolve failed: \(error.localizedDescription)")
        }
        return (nil, nil)
    }
}
