import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct VoiceToDocLiteApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        // ✅ メインはタブを持つ MainView に戻す
        WindowGroup {
            MainView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.settings)
        }

        #if os(macOS)
        // ✅ SwiftUIの設定ウインドウ（⌘, / メニュー「設定…」で出る）
        Settings {
            SettingsRootView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.settings)
        }
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // ✅ AppState/Settings を強保持（ウインドウ有無に関係なく生存）
    //   ※バックアップ版の初期化式に合わせ、必要なら引数を調整してください
    let appState = AppState(transcriber: WhisperKitTranscriber())
    let settings = SettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // グローバルホットキー & 録音コアを 1 回だけ初期化
        HotKeyCenter.shared.install()
        _ = AudioCapture.shared
        print("[App] Background core initialized (HotKey/AudioCapture)")

        // ⌥⌘P でパレット開閉（既存のコントローラ呼び出し）
        
    }

    // ウインドウをすべて閉じてもアプリは常駐
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    
    
}
