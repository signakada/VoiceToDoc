import SwiftUI
import Carbon.HIToolbox

/// 設定画面に組み込む “ホットキー & パレット” セクション
/// 既存 SettingsRootView からこの View をタブとして追加してください。
struct HotKeySettingsTab: View {
    @StateObject private var prefs = HotKeyPrefs.shared

    // プルダウンに並べる候補（必要なら増やせます）
    private let keyCombos = [
        "⌥⌘R",
        "⌃⌥⌘R",
        "⌥R",
        "⌘R",
        "F19"
    ]
    private let paletteCombos = [
        "⌥⌘P",
        "⌃⌥⌘P",
        "⌘P",
        "F19"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ホットキー & パレット")
                .font(.title2).bold()

            Toggle("録音パレットを表示", isOn: $prefs.showPalette)
                .onChange(of: prefs.showPalette) { _ in
                    // showPalette 変更時は通知→コントローラ側で表示/非表示
                    // (FloatingRecorderPaletteController が通知を受け取って処理)
                }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ホットキー")
                        .font(.headline)

                    HStack {
                        Text("録音トグル")
                            .frame(width: 100, alignment: .leading)
                        Picker("", selection: $prefs.recordCombo) {
                            ForEach(keyCombos, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Text(hint(for: prefs.recordCombo))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("パレット表示/非表示")
                            .frame(width: 100, alignment: .leading)
                        Picker("", selection: $prefs.paletteCombo) {
                            ForEach(paletteCombos, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Text(hint(for: prefs.paletteCombo))
                            .foregroundStyle(.secondary)
                    }

                    Text("※ 「右オプションキー」単体は macOS のグローバルホットキー仕様上サポートが不安定なため、F19 などの単独キー、または修飾キー＋文字の組み合わせを推奨します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button {
                            // ユーザーが手動で “再適用” できるボタン
                            NotificationCenter.default.post(name: .init("hotkey.reload"), object: nil)
                        } label: {
                            Label("ホットキーを再適用", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            // 起動時に HotKeyCenter へ反映（存在すれば）
            NotificationCenter.default.post(name: .init("hotkey.reload"), object: nil)
            // パレット表示状態も反映
            NotificationCenter.default.post(name: .init("palette.visibility.changed"),
                                            object: nil,
                                            userInfo: ["visible": prefs.showPalette])
        }
    }

    private func hint(for combo: String) -> String {
        switch combo {
        case "⌥⌘R":   return "Option + Command + R"
        case "⌃⌥⌘R":  return "Control + Option + Command + R"
        case "⌥R":     return "Option + R"
        case "⌘R":     return "Command + R"
        case "⌥⌘P":   return "Option + Command + P"
        case "⌃⌥⌘P":  return "Control + Option + Command + P"
        case "⌘P":     return "Command + P"
        case "F19":     return "F19（単独キー）"
        default:        return ""
        }
    }
}
