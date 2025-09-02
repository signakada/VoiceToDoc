import Foundation
import Combine

/// R2: 録音完了通知 → 転写起動の起点を一本化
@MainActor
final class AppState: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var lastOutput: String = ""
    @Published var lastErrorMessage: String = ""
    // 最後に扱った音声ファイルと、そのセッションフォルダ（Tab1/2/3で共通利用）
    @Published var lastAudioURL: URL?
    @Published var lastSessionFolder: URL?

    private var cancellables = Set<AnyCancellable>()
    private let transcriber: Transcriber

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        NotificationCenter.default.publisher(for: Notification.Name("audioFileReady"))
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                guard let url = note.userInfo?["url"] as? URL else {
                    print("[AppState] ⚠️ audioFileReady に URL が含まれていません")
                    return
                }
                self.lastAudioURL = url
                self.startTranscription(for: url)
            }
            .store(in: &cancellables)
        // Transcriber 側で確定したセッションフォルダ（~/Documents/音声カルテ/日時）を反映
        NotificationCenter.default.publisher(for: Notification.Name("sessionFolderReady"))
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
        // 要約完了通知で summary.txt を保存（Tab1/2/3 のUIに依存せず中央集約）
        NotificationCenter.default.publisher(for: Notification.Name("summaryReady"))
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self = self else { return }
                guard let text = note.userInfo?["text"] as? String else { return }
                guard let folder = self.lastSessionFolder else {
                    print("[AppState] ⚠️ lastSessionFolder is nil; skip saving summary.txt")
                    return
                }
                let fileURL = folder.appendingPathComponent("summary.txt")
                do {
                    try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                    print("[AppState] 📝 saved summary to \(fileURL.path)")
                } catch {
                    print("[AppState] ❌ failed to save summary: \(error)")
                }
            }
            .store(in: &cancellables)
    }

    private func startTranscription(for url: URL) {
        isBusy = true
        lastErrorMessage = ""

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = values.fileSize ?? 0
            guard size > 0 else {
                isBusy = false
                lastErrorMessage = "録音ファイルが空です (0 byte)"
                print("[AppState] ❌ 0 byte: \(url.path)")
                return
            }
        } catch {
            isBusy = false
            lastErrorMessage = "ファイル確認に失敗: \(error.localizedDescription)"
            print("[AppState] ❌ stat error: \(error)")
            return
        }

        print("[AppState] 🚀 転写開始 → \(url.lastPathComponent)")

        let lang = "ja" // R6 で設定反映

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.transcriber.transcribeFile(at: url, language: lang) { [weak self] finalText in
                    guard let self = self else { return }
                    self.lastOutput = finalText
                    // 自動保存：転写テキストをセッションフォルダに書き出し
                    if let folder = self.lastSessionFolder {
                        let fileURL = folder.appendingPathComponent("transcript.txt")
                        let legacyURL = folder.appendingPathComponent("transcription.txt")
                        do {
                            try finalText.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                            try? finalText.data(using: .utf8)?.write(to: legacyURL, options: .atomic)
                            print("[AppState] 📝 saved transcription to \(fileURL.path)")
                        } catch {
                            print("[AppState] ❌ failed to save transcription: \(error)")
                        }
                    } else {
                        print("[AppState] ⚠️ lastSessionFolder is nil; skip saving transcription.txt")
                    }
                }
                print("[AppState] ✅ 転写完了: decoded=\(self.lastOutput.count) chars")
                self.isBusy = false
            } catch {
                self.lastErrorMessage = error.localizedDescription
                self.isBusy = false
                print("[AppState] ❌ 転写失敗: \(error.localizedDescription)")
            }
        }
    }
}
