import Foundation

/// 文字起こし用の共通プロトコル
protocol Transcriber {
    /// モデルのプリウォームなど必要なら実施（重複呼び出しは実装側で吸収OK）
    func prewarmIfNeeded()

    /// ローカル音声ファイルを文字起こしして、完了時に全文を返す
    func transcribeFile(at url: URL, language: String, storageBookmarkData: Data?) async throws -> String

    /// 進行中の処理をキャンセル
    func cancel()
}

