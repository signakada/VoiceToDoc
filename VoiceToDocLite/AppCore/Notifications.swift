import Foundation

// アプリ内で共有する通知名を一元管理
extension Notification.Name {
    /// 録音（または外部処理）でWAV保存が完了し、ファイルURLが用意できたとき
    static let audioFileReady          = Notification.Name("audioFileReady")
}
