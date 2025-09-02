import Foundation

/// 軽量な後処理（重複除去 + 句読点の簡易整形）をまとめたユニット。
/// 文字列処理のみなので、マイク入力／ファイル入力どちらにも流用できます。
enum TextPostProcessor {
    /// エントリポイント：言語別に後処理。
    static func process(_ text: String, language: String) -> String {
        let deDuped = removeLocalDuplicates(text)
        if language.lowercased().hasPrefix("ja") {
            return punctuateLiteJA(deDuped)
        } else {
            return deDuped
        }
    }

    // MARK: - 重複除去（隣接する短い繰り返しの抑制）
    /// 文単位に分割し、隣接する完全一致やほぼ一致（末尾の1〜2文字差）を除去します。
    private static func removeLocalDuplicates(_ text: String) -> String {
        let sentences = splitIntoSentences(text)
        var result: [String] = []
        var lastNorm: String? = nil

        for raw in sentences {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            let norm = normalizeForCompare(s)
            if let last = lastNorm {
                if norm == last { continue } // 完全一致は落とす
                // 末尾1〜2文字差のほぼ一致（例: 「…でした」「…でした。」）
                if abs(norm.count - last.count) <= 2 {
                    if norm.hasPrefix(last) || last.hasPrefix(norm) { continue }
                }
            }
            result.append(s)
            lastNorm = norm
        }
        // 文末の重複除去後は連結して返す
        return joinSentences(result)
    }

    /// 文分割（日本語でも使える素朴なルール）。
    private static func splitIntoSentences(_ text: String) -> [String] {
        // 。！？!? または改行で概ね区切る（句読点が無い連なりも拾うため、長すぎる塊は途中で切る）
        let pattern = #"(?<=[。！？!?])\s+|\n+"#
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        let regex = try! NSRegularExpression(pattern: pattern)
        let full = NSRange(cleaned.startIndex..., in: cleaned)

        var parts: [String] = []
        var lastIndex = cleaned.startIndex

        // 正規表現にマッチした箇所を区切りとして分割
        for m in regex.matches(in: cleaned, range: full) {
            guard let range = Range(m.range, in: cleaned) else { continue }
            let chunk = String(cleaned[lastIndex..<range.lowerBound])
            parts.append(chunk)
            lastIndex = range.upperBound
        }
        // 末尾の残り
        if lastIndex <= cleaned.endIndex {
            parts.append(String(cleaned[lastIndex...]))
        }

        // 句点無しに長く続く場合の保険：60字程度でソフト分割
        return parts.flatMap { chunk -> [String] in
            if chunk.count > 80 {
                return chunk.chunked(by: 60)
            } else {
                return [chunk]
            }
        }
    }

    /// 文配列を適切な句点で連結。
    private static func joinSentences(_ parts: [String]) -> String {
        var out: [String] = []
        for s in parts {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if endsWithSentencePunct(trimmed) {
                out.append(trimmed)
            } else {
                out.append(trimmed + "。")
            }
        }
        // 連続の「。。」などを正規化
        let joined = out.joined(separator: "")
        return normalizePunct(joined)
    }

    /// 比較用に正規化（空白・句読点を除去して小文字化）。
    private static func normalizeForCompare(_ s: String) -> String {
        let lowered = s.lowercased()
        let removeSet = CharacterSet(charactersIn: " 、，,。．.\n\t")
        let filtered = lowered.unicodeScalars.filter { !removeSet.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func endsWithSentencePunct(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return "。．.!！?？".contains(last)
    }

    // MARK: - 日本語の簡易句読点整形
    private static func punctuateLiteJA(_ text: String) -> String {
        var t = text
        // 連続句点の正規化
        t = normalizePunct(t)
        // 読点が全く無い長文に軽く「、」を入れる（読点密度が低い場合のみ）
        t = insertLightCommaIfNeeded(t)
        // 余分な空白を削除
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePunct(_ text: String) -> String {
        var t = text
        // 全角・半角句点の正規化 + 連続の句点を1つに
        t = t.replacingOccurrences(of: "．．", with: "。")
        t = t.replacingOccurrences(of: "..", with: "。")
        t = t.replacingOccurrences(of: "．", with: "。")
        while t.contains("。。") { t = t.replacingOccurrences(of: "。。", with: "。") }
        return t
    }

    /// 読点が少ない長文に軽く「、」を入れる（助詞や接続語の前）
    private static func insertLightCommaIfNeeded(_ text: String) -> String {
        // 既に「、」が多いなら何もしない
        let commaCount = text.filter { $0 == "、" }.count
        if commaCount >= 3 { return text }

        // 目安：接続の直後や言い換えの前に 1〜2 箇所だけ
        var t = text
        let rules: [(pattern: String, replacement: String)] = [
            (#"(?<=[^、\n]{12,})(それで|そして|しかし|でも|ただ|つまり|一方で|だから|なので)"#, "、$1"),
            (#"(例えば|いわゆる|具体的には)"#, "、$1")
        ]
        for rule in rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern) {
                t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: rule.replacement)
            }
        }
        return t
    }
}

private extension String {
    func chunked(by size: Int) -> [String] {
        guard size > 0 else { return [self] }
        var out: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[start..<end]))
            start = end
        }
        return out
    }
}
