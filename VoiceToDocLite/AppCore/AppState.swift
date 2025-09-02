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
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            
            do {
                // 文字起こし結果を直接取得
                let transcriptionText = try await self.transcriber.transcribeFile(at: url, language: "ja", storageBookmarkData: storageBookmarkData)
                let processedText = TextPostProcessor.process(transcriptionText, language: "ja")
                
                // 文字起こし完了後、要約処理を開始
                NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "summarizing"])
                
                let sys = self.settings.resolveSystemPromptForSelectedPreset()
                let summary = try await SummarizerService.shared.summarize(processedText, systemPrompt: sys)

                // 【修正】UI更新とファイル保存処理を明確に分離
                // UI関連の更新はメインスレッドで行う
                await MainActor.run {
                    self.lastOutput = processedText // 転写結果を更新
                    self.lastSummary = summary     // 要約結果を更新
                    self.isBusy = false
                    self.lastErrorMessage = ""

                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    #endif
                    
                    NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "done"])
                    NotificationCenter.default.post(name: .init("summaryReady"), object: nil, userInfo: ["text": summary])
                    
                    print("[AppState] ✅ 転写・要約完了 & クリップボードにコピー")
                }
                
                // 【修正】ファイル保存処理をバックグラウンドスレッドで実行
                if let folder = self.lastSessionFolder {
                    let fileURL = folder.appendingPathComponent("summary.txt")
                    try summary.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                    print("[AppState] 📝 saved summary to \(fileURL.path)")
                }

            } catch {
                // エラー発生時、メインスレッドで状態を更新
                DispatchQueue.main.async {
                    self.lastErrorMessage = error.localizedDescription
                    self.isBusy = false
                    print("[AppState] ❌ 転写/要約失敗: \(error.localizedDescription)")
                    NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "idle"])
                }
            }
        }
    }
    
    // 【追加】ブックマークからURLを解決するヘルパー関数
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
}

