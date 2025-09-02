import Foundation
import Combine

/// 要約関連のUI状態を保持するモデル（このファイルは SummaryState のみを定義）
final class SummaryState: ObservableObject {

    /// 要約対象のテキスト断片
    @Published var segments: [String] = []

    /// 生成された要約テキスト
    @Published var summary: String = ""

    /// 要約処理中フラグ
    @Published var isSummarizing: Bool = false

    /// エラーメッセージ（nil なら正常）
    @Published var errorMessage: String?

    /// 直近更新のタイムスタンプ（UI の onReceive などで使える）
    @Published var lastUpdated: Date = .distantPast

    func reset() {
        segments.removeAll()
        summary = ""
        isSummarizing = false
        errorMessage = nil
        lastUpdated = Date()
    }

    func setSummary(_ text: String) {
        summary = text
        lastUpdated = Date()
    }

    func appendSegment(_ text: String) {
        segments.append(text)
        lastUpdated = Date()
    }

    func setError(_ message: String) {
        errorMessage = message
        isSummarizing = false
        lastUpdated = Date()
    }
}
