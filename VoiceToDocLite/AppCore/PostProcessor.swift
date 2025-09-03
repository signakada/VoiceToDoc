import Foundation

enum PostProcessor {
    static func normalize(_ text: String) -> String {
        // 例：全角英数→半角、連続スペース→1つ など最小限
        let collapsedSpaces = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return collapsedSpaces.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
