import Foundation

/// 要約プリセット（タイトル＋プロンプトを一元管理）
public enum SummaryPreset: String, CaseIterable, Identifiable {
    case none          // 要約しない＝素通し
    case soap          // SOAP
    case shoshinSoap   // 初診+SOAP
    case memo          // 面接記録
    case certificate   // 診断書フォーマット

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none:          return "要約しない"
        case .soap:          return "SOAP"
        case .shoshinSoap:   return "初診+SOAP"
        case .memo:          return "面接記録"
        case .certificate:   return "診断書（下書き）"
        }
    }

    /// LLM に渡す指示テキスト
    public var prompt: String {
        switch self {
        case .none:
            return "そのまま返してください。編集や要約はしないでください。"
        case .soap:
            return """
            あなたは精神科の記録担当者です。以下の会話書き起こしをもとに、SOAP形式に従って簡潔な箇条書きで要約してください。
            できるだけ簡潔に記載してください。
            【ルール】
            ・各項目の文頭には記号（ドット、ハイフン、数字など）を付けず、改行のみで列挙すること
            ・S（Subjective）：本人の主観的訴えや語り（感情、考え、悩みなど）を記載すること。感情や語調、主観的表現（「不安」、「つらい」など）を重視して記載
            ・O（Objective）：診察時の客観的所見（バイタル、検査値）を記載すること。評価は入れない。記載事項がない時には空白にする
            ・A（Assessment）：SとO、医師の発言から得られるに医師の視点から導の評価。感情の変化や適応状況などを含め、状態を簡潔に記述する。憶測は不要。
            ・P（Plan）：会話内容からえられる今後の治療方針や対応内容（処方、心理的支援、観察方針、医師からの言葉かけなど）、医師のアドバイスや助言を記載すること。会話内容以外の憶測、ガイドラインからの評価は不要。

            【出力形式】

            （Ｓ）：
            （患者の語りを元にした簡潔な箇条書き）

            （Ｏ）：
            （バイタルや所見などがある場合のみ記載。なければ「落ち着いて話す」と記載）

            （Ａ）：
            （会話内容から得られるて医師の視点で行う評価）

            （Ｐ）：
            （治療や対応方針の記述）
            """
        case .shoshinSoap:
            return """
            あなたは精神科クリニックの診療アシスタントです。以下の会話書き起こし分から、医療文書の形式で要約を作り、その後カルテ記載用にSOAP形式での記録を出力してください。
            まず医療文書の形式で要約を作成してください。＜主訴＞、＜生活歴＞、＜既往歴および家族歴＞、＜現病歴＞、＜現症＞に分けて記載してください。現病歴については、精神疾患の発症から現在に至るまでを記載すること。
            その後、SOAP形式に従って簡潔な箇条書きで要約してください。
            できるだけ簡潔に記載してください。
            【ルール】
            ・各項目の文頭には記号（ドット、ハイフン、数字など）を付けず、改行のみで列挙すること
            ・S（Subjective）：本人の主観的訴えや語り（感情、考え、悩みなど）を記載すること。感情や語調、主観的表現（「不安」、「つらい」など）を重視して記載
            ・O（Objective）：診察時の客観的所見（バイタル、検査値）を記載すること。評価は入れない。記載事項がない時には空白にする
            ・A（Assessment）：SとO、医師の発言から得られるに医師の視点から導の評価。感情の変化や適応状況、ストレス耐性などを含め、状態を簡潔に記述する
            ・P（Plan）：会話内容からえられる今後の治療方針や対応内容（処方、心理的支援、観察方針、医師からの言葉かけなど）、医師のアドバイスや助言を記載すること。会話内容以外の憶測、ガイドラインからの評価は不要。

            出力形式は以下のようにしてください

            【主訴】

            【生活歴】

            【既往歴および家族歴】

            【現病歴】

            【現症】

            （Ｓ）：
            （患者の語りを元にした簡潔な箇条書き）

            （Ｏ）：
            （バイタルや所見などがある場合のみ記載。なければ「落ち着いて話す」と記載）

            （Ａ）：
            （会話内容から得られるて医師の視点で行う評価）

            （Ｐ）：
            （治療や対応方針の記述）

            """
        case .memo:
            return """
            次の会話記録を、臨床面接記録として簡潔に要点化してください。時系列がわかるようにし、重要な所見・患者の発言・介入内容を明確に。日本語。
            """
        case .certificate:
            return """
            次の内容を診断書の下書き用に整理してください。事実と推測を区分し、必要な医学的所見を簡潔に。日本語。
            """
        }
    }
}

/// UI 用：一覧やタイトル解決をまとめて扱うストア
public final class PresetStore {
    public static let shared = PresetStore()
    private init() {}

    public var all: [SummaryPreset] { SummaryPreset.allCases }
    public var titles: [String] { all.map { $0.title } }

    public var defaultPreset: SummaryPreset { .soap }

    public func byTitle(_ title: String) -> SummaryPreset? {
        return all.first { $0.title == title }
    }
}
