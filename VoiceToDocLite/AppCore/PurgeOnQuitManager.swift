import Foundation
#if os(macOS)
import AppKit
#endif

/// アプリ終了時に「音声カルテ」配下の **音声ファイルのみ** を削除するマネージャ。
/// - 仕様
///   - SettingsStore と直接は結合しない（UserDefaults と Bookmark を直接読む）
///   - `purge_on_quit == true` のときのみ動作
///   - 保存先フォルダは `storage_base_bookmark`（セキュリティスコープ付き）
///     があればそれ、なければ App の Documents を基点にする
///   - 削除対象拡張子: wav, m4a, mp3, aac, aiff, aif, caf
enum PurgeOnQuitManager {

    // MARK: Public

    /// NSApplication.willTerminate を購読して登録する。
    /// 何度呼んでも一回だけ有効化。
    @discardableResult
    static func start() -> Bool {
        #if os(macOS)
        guard !isStarted else { return false }
        isStarted = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.handleWillTerminate()
        }
        print("[Purge] observer installed")
        return true
        #else
        return false
        #endif
    }

    // MARK: Private

    private static var isStarted = false

    private static func handleWillTerminate() {
        let ud = UserDefaults.standard
        let purge = ud.bool(forKey: "purge_on_quit")
        guard purge else {
            print("[Purge] skip (purge_on_quit = false)")
            return
        }

        // 保存基点フォルダの解決
        let baseURL = resolveStorageBaseURLFromDefaults()
            ?? (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)

        guard let root = baseURL else {
            print("[Purge] baseURL not resolved")
            return
        }

        // 音声カルテのルート
        let karteRoot = root.appendingPathComponent("音声カルテ", isDirectory: true)

        // 対象拡張子
        let audioExts: Set<String> = ["wav","m4a","mp3","aac","aiff","aif","caf"]

        // セキュリティスコープ
        let didAccess = startScopedAccessIfNeeded(url: root)
        defer { stopScopedAccessIfNeeded(url: root, did: didAccess) }

        // 走査して音声のみ削除
        var removedCount = 0
        if let enumerator = FileManager.default.enumerator(at: karteRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let ext = fileURL.pathExtension.lowercased()
                if audioExts.contains(ext) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        removedCount += 1
                    } catch {
                        print("[Purge] remove failed: \(fileURL.lastPathComponent) -> \(error)")
                    }
                }
            }
        }

        print("[Purge] done: removed \(removedCount) audio files under \(karteRoot.path)")
    }

    /// UserDefaults 上のブックマークを解決
    private static func resolveStorageBaseURLFromDefaults() -> URL? {
        let key = "storage_base_bookmark"
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return url
        } catch {
            print("[Purge] resolve bookmark failed: \(error)")
            return nil
        }
    }

    private static func startScopedAccessIfNeeded(url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }

    private static func stopScopedAccessIfNeeded(url: URL, did: Bool) {
        if did { url.stopAccessingSecurityScopedResource() }
    }
}
