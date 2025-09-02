import Foundation

/// 話者分離後の一片
public struct DiarizedChunk: Equatable {
    public let speaker: String   // 例: "医", "患" など
    public let text: String
    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// 話者分離エンジンのプロトコル（将来差し替え用）
public protocol Diarizer {
    /// @param fullText 書き起こし結果の全文
    /// @param wavURL   元音声ファイル（将来の高精度版で使用）
    /// @return 話者ラベル付きのチャンク配列。未対応なら nil を返して呼び出し側でスキップ可。
    func diarize(fullText: String, wavURL: URL?) -> [DiarizedChunk]?
}

/// 何もしない実装（今は常に nil を返す）
public struct NoopDiarizer: Diarizer {
    public init() {}
    public func diarize(fullText: String, wavURL: URL?) -> [DiarizedChunk]? { nil }
}
