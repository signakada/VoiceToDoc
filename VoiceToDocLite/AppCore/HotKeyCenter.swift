import Foundation
import Carbon.HIToolbox
import AppKit

private func HotKeyEventHandlerCallback(_ nextHandler: EventHandlerCallRef?, _ eventRef: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let eventRef = eventRef else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(eventRef,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    if status == noErr {
        switch hotKeyID.id {
        case 1: // ⌥⌘R
            // 修正：録音開始/停止を直接呼び出す
            DispatchQueue.main.async { HotKeyCenter.shared.hk_toggleRecord() }
        case 2: // ⌥⌘P
            DispatchQueue.main.async {
                FloatingRecorderPaletteController.shared.toggle()
            }
        case 3: // 予備 F19
            // 修正：録音開始/停止を直接呼び出す
            DispatchQueue.main.async { HotKeyCenter.shared.hk_toggleRecord() }
        default:
            break
        }
    }
    return noErr
}
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyToggleRec: EventHotKeyRef?
    private var hotKeyTogglePalette: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var installed = false

    private var hk_isRecording = false
    private var hk_isToggling = false

    private init() {
        // AudioCapture 側からの状態通知（バックアップ実装が投げている想定）
        NotificationCenter.default.addObserver(self, selector: #selector(hk_onState(_:)), name: .init("audioCapture.state"), object: nil)

        // ★ UIボタンや他経路の通知名を両方購読（どちらでも録音トグル）
        NotificationCenter.default.addObserver(self, selector: #selector(hk_onExternalToggle(_:)), name: .init("ui.toggleRecord"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hk_onExternalToggle(_:)), name: .init("hotkey.record.toggle"), object: nil)
    }

    func install() {
        guard !installed else { return }
        installed = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let statusInstall = InstallEventHandler(GetEventDispatcherTarget(), HotKeyEventHandlerCallback, 1, &eventSpec, nil, &eventHandlerRef)
        if statusInstall != noErr { NSLog("[HotKey] InstallEventHandler failed: \(statusInstall)") }

        var id1 = EventHotKeyID(signature: OSType(0x56444c31), id: 1) // 'VDL1'
        let s1 = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), id1, GetEventDispatcherTarget(), 0, &hotKeyToggleRec)
        if s1 != noErr { NSLog("[HotKey] Register ⌥⌘R failed: \(s1)") }

        var id2 = EventHotKeyID(signature: OSType(0x56444c32), id: 2) // 'VDL2'
        let s2 = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey), id2, GetEventDispatcherTarget(), 0, &hotKeyTogglePalette)
        if s2 != noErr { NSLog("[HotKey] Register ⌥⌘P failed: \(s2)") }

        var id3 = EventHotKeyID(signature: OSType(0x56444c33), id: 3) // 'VDL3'
        let s3 = RegisterEventHotKey(UInt32(kVK_F19), 0, id3, GetEventDispatcherTarget(), 0, &hotKeyToggleRec)
        if s3 != noErr { NSLog("[HotKey] Register F19 failed: \(s3)") } else { NSLog("[HotKey] fallback registered: F19 for record toggle") }

        NSLog("[HotKey] installed (⌥⌘R:rec toggle, ⌥⌘P:palette)")
    }

    @objc private func hk_onState(_ note: Notification) {
        if let r = note.userInfo?["recording"] as? Bool { hk_isRecording = r }
    }
    @objc private func hk_onExternalToggle(_ note: Notification) {
        hk_toggleRecord()
    }

    func hk_toggleRecord() {
        // ...
        if hk_isRecording {
            NSLog("[HotKey] ▶︎ stop() via AudioCapture (background-safe)")
            AudioCapture.shared.stop()
            hk_isRecording = false
        } else {
            NSLog("[HotKey] ▶︎ start() via AudioCapture (background-safe)")
            AudioCapture.shared.start()
            hk_isRecording = true
        }
        // 後方互換性のため一応ブロードキャスト
        // この通知は、録音状態をUIに反映するために必要
        NotificationCenter.default.post(name: .init("audioCapture.state"), object: nil, userInfo: ["recording": hk_isRecording])
    }
}
