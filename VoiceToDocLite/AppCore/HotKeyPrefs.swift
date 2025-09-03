import Foundation
import Combine
import Carbon.HIToolbox

/// ホットキー & パレット表示のユーザ設定（UserDefaults 永続化）
/// 既存 SettingsStore に手を入れずに独立運用できる軽量ストア。
final class HotKeyPrefs: ObservableObject {
    static let shared = HotKeyPrefs()

    // MARK: - 公開プロパティ（UIバインディング）
    @Published var showPalette: Bool {
        didSet {
            UserDefaults.standard.set(showPalette, forKey: Keys.showPalette)
            // UI 反映：パレット表示/非表示の通知
            NotificationCenter.default.post(name: .init("palette.visibility.changed"),
                                            object: nil,
                                            userInfo: ["visible": showPalette])
        }
    }

    /// 録音トグルのキーコンボ表示（内部は文字列プリセット）
    /// 例: "⌥⌘R", "⌃⌥⌘R", "F19"
    @Published var recordCombo: String {
        didSet {
            UserDefaults.standard.set(recordCombo, forKey: Keys.recordCombo)
            // HotKey 再登録の通知
            NotificationCenter.default.post(name: .init("hotkey.reload"), object: nil)
        }
    }

    /// パレット表示/非表示トグルのキーコンボ表示
    @Published var paletteCombo: String {
        didSet {
            UserDefaults.standard.set(paletteCombo, forKey: Keys.paletteCombo)
            NotificationCenter.default.post(name: .init("hotkey.reload"), object: nil)
        }
    }

    // MARK: - 初期化
    private init() {
        let d = UserDefaults.standard
        self.showPalette = d.object(forKey: Keys.showPalette) as? Bool ?? true
        self.recordCombo = d.string(forKey: Keys.recordCombo) ?? "⌥⌘R"
        self.paletteCombo = d.string(forKey: Keys.paletteCombo) ?? "⌥⌘P"
    }

    // MARK: - 公開: Carbon 登録用パラメータに解決
    /// 表示文字列を Carbon の (keyCode, modifiers) に解釈する
    /// サポート: "⌥⌘R", "⌃⌥⌘R", "⌥R", "⌘R", "F19"
    func resolveRecordKey() -> (keyCode: UInt32, modifiers: UInt32) {
        keyComboToCarbon(recordCombo)
    }
    func resolvePaletteKey() -> (keyCode: UInt32, modifiers: UInt32) {
        keyComboToCarbon(paletteCombo)
    }

    // MARK: - 文字列 → Carbon 変換
    private func keyComboToCarbon(_ s: String) -> (UInt32, UInt32) {
        // 例: "⌃⌥⌘R" / "⌥⌘R" / "F19"
        var modifiers: UInt32 = 0
        var keyCode: UInt32 = UInt32(kVK_ANSI_R) // デフォルトは R

        let upper = s.uppercased()
        if upper.contains("⌃") || upper.contains("CTRL") { modifiers |= UInt32(controlKey) }
        if upper.contains("⌥") || upper.contains("ALT")  { modifiers |= UInt32(optionKey)  }
        if upper.contains("⌘") || upper.contains("CMD")  { modifiers |= UInt32(cmdKey)     }
        if upper.contains("⇧") || upper.contains("SHIFT"){ modifiers |= UInt32(shiftKey)   }

        if upper.contains("F19") {
            keyCode = UInt32(kVK_F19)
            // F19 単独を許可（モディファイア無）
            return (keyCode, modifiers)
        }

        // 末尾の英字をキーとして解釈（R など）
        if let last = upper.unicodeScalars.last, ("A"..."Z").contains(Character(last)) {
            switch Character(last) {
            case "R": keyCode = UInt32(kVK_ANSI_R)
            case "P": keyCode = UInt32(kVK_ANSI_P)
            default:  keyCode = UInt32(kVK_ANSI_R)
            }
        }
        return (keyCode, modifiers)
    }

    // MARK: - Keys
    private enum Keys {
        static let showPalette  = "prefs.showPalette"
        static let recordCombo  = "prefs.recordCombo"
        static let paletteCombo = "prefs.paletteCombo"
    }
}
