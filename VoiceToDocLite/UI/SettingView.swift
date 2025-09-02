//
//  SettingView.swift
//  VoiceToDocLite
//


import SwiftUI

/// ルートから呼ばれる設定画面のエントリ
struct SettingView: View {
    var body: some View {
        SettingsRootView()   // 既存の本体（別ファイル）をそのまま表示
    }
}

// プレビュー（任意）
#Preview {
    SettingView()
        .environmentObject(AppState(transcriber: WhisperKitTranscriber()))
        .environmentObject(SettingsStore())
}
