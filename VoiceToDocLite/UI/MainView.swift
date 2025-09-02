
import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Main
struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var isRecording: Bool = false
    @State private var lastToggleAt: Date?

    var body: some View {
        TabView {
            // === 1) 音声入力（既存 UI） ===
            ContentView()
                .environmentObject(appState)
                .environmentObject(settings)
                .tabItem { Label("音声入力", systemImage: "record.circle") }

            // === 2) 音声ファイル ===
            FileSummaryTab()
                .environmentObject(appState)
                .environmentObject(settings)
                .tabItem { Label("音声ファイル", systemImage: "waveform.path") }

            // === 3) テキスト ===
            TextSummaryTab()
                .environmentObject(settings)
                .tabItem { Label("テキスト", systemImage: "text.alignleft") }

            // === 4) 履歴 ===
            HistoryTab()
                .environmentObject(settings)
                .tabItem { Label("履歴", systemImage: "clock") }
        }
        // ← ここまでが TabView の中身
        .onAppear {
            // グローバルホットキー登録（重複ガードあり）
            HotKeyCenter.shared.install()
#if os(macOS)
            // パレットコントローラの初期化
            _ = FloatingRecorderPaletteController.shared
#endif
            // 小型の録音パレットを表示（不要ならコメントアウト）
            NotificationCenter.default.post(name: .init("palette.visibility.changed"), object: nil, userInfo: ["visible": true])
        }
        
        
        // AudioCapture 側が状態通知を出す場合はそれも反映（任意）
        .onReceive(NotificationCenter.default.publisher(for: .init("audioCapture.state"))) { note in
            if let rec = (note.userInfo as? [String: Any])?["recording"] as? Bool {
                isRecording = rec
            }
        }
    }
}

// MARK: - Helpers (common)
fileprivate func karteBaseFolder() throws -> URL {
    let fm = FileManager.default
    let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let base = docs.appendingPathComponent("音声カルテ", isDirectory: true)
    if !fm.fileExists(atPath: base.path) { try fm.createDirectory(at: base, withIntermediateDirectories: true) }
    return base
}

fileprivate func newSessionFolder(now: Date = Date(), suggestedName: String? = nil) throws -> URL {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
    let name = suggestedName ?? fmt.string(from: now)
    let base = try karteBaseFolder()
    let folder = base.appendingPathComponent(name, isDirectory: true)
    if !FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    return folder
}

fileprivate func writeText(_ text: String, to url: URL) throws {
    try text.data(using: .utf8)?.write(to: url, options: .atomic)
}

fileprivate func readText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

fileprivate func copyAudioToSession(_ src: URL, session: URL) throws -> URL {
    let dst = session.appendingPathComponent(src.lastPathComponent)
    if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
    try FileManager.default.copyItem(at: src, to: dst)
    return dst
}

// MARK: - 2) 音声ファイル：D&D/Importer → 左=書き起こし, 右=要約（TextEditorへのドロップ完全無効）
private struct FileSummaryTab: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    // Import
    @State private var isImporterPresented = false

    // セッション
    @State private var sessionFolder: URL?
    @State private var importedAudio: URL?
    @State private var transcript: String = ""
    @State private var summary: String = ""

    // 要約UI
    @State private var isSummarizing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("音声ファイル").font(.title2).bold()
                Spacer()
                Button { isImporterPresented = true } label: { Label("ファイルを選択", systemImage: "folder") }
            }

            HStack(alignment: .top, spacing: 12) {
                // 左：書き起こし
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("書き起こし")
                        Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }
                    }
                    ZStack {
                        NonDroppableTextEditor(text: $transcript)
                        // 透明オーバーレイでドロップ捕捉
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .dropDestination(for: URL.self) { urls, _ in
                                if let u = urls.first { importAudio(u) }
                                return true
                            }
                            .dropDestination(for: String.self) { _, _ in true }
                            .allowsHitTesting(false)
                    }
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }

                // 右：要約
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("要約")
                        Spacer()
                        // プリセット選択（Settings と連動）
                        Picker("プリセット", selection: Binding(
                            get: { settings.selectedPresetKey },
                            set: { settings.setSelectedPreset(key: $0) }
                        )) {
                            Section("デフォルト（内蔵）") {
                                ForEach(settings.builtinPresets) { p in Text(p.title).tag(p.key) }
                            }
                            if !settings.customPresets.isEmpty {
                                Section("カスタム") {
                                    ForEach(settings.customPresets) { p in Text(p.title).tag(p.key) }
                                }
                            }
                        }
                        .pickerStyle(.menu)

                        Button {
                            Task { await summarizeNow() }
                        } label: {
                            if isSummarizing { ProgressView() } else { Label("要約する", systemImage: "sparkles") }
                        }
                        .disabled(isSummarizing || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }
                    }
                    ZStack {
                        NonDroppableTextEditor(text: $summary)
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .dropDestination(for: URL.self) { urls, _ in
                                if let u = urls.first { importAudio(u) }
                                return true
                            }
                            .dropDestination(for: String.self) { _, _ in true }
                            .allowsHitTesting(false)
                    }
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }
            }

            if let msg = errorMessage { Text(msg).foregroundStyle(.red) }
            Spacer()
        }
        .padding()
        // 画面全体で URL ドロップ受付（どこに落としても取り込み）
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first { importAudio(u) }
            return true
        }
        .dropDestination(for: String.self) { _, _ in false }
        // ファイルインポータ
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio, .wav, .mpeg4Audio, .mp3], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let src = urls.first { importAudio(src) }
            case .failure(let e): errorMessage = "❌ 取得失敗: \(e.localizedDescription)"
            }
        }
        // 転写完了を受けて左ペインへ反映
        .onChange(of: appState.lastOutput) { out in
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            transcript = t
            if let session = sessionFolder {
                try? writeText(t, to: session.appendingPathComponent("transcription.txt"))
            }
        }
    }

    private func importAudio(_ src: URL) {
        errorMessage = nil
        do {
            let folder = try newSessionFolder(suggestedName: nil)
            sessionFolder = folder
            let copied = try copyAudioToSession(src, session: folder)
            importedAudio = copied
            NotificationCenter.default.post(name: .init("audioFileReady"), object: nil, userInfo: ["url": copied])
        } catch {
            errorMessage = "❌ インポート失敗: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func summarizeNow() async {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let system = settings.resolveSystemPromptForSelectedPreset()
            let out = try await SummarizerService.shared.summarize(transcript, systemPrompt: system)
            summary = out
            if let session = sessionFolder {
                try? writeText(out, to: session.appendingPathComponent("summary.txt"))
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 3) テキスト要約（プリセット/要約ボタン/コピー）
private struct TextSummaryTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var inputText: String = ""
    @State private var outputText: String = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("テキスト要約").font(.title2).bold()
                Spacer()
                Picker("プリセット", selection: Binding(
                    get: { settings.selectedPresetKey },
                    set: { settings.setSelectedPreset(key: $0) }
                )) {
                    Section("デフォルト（内蔵）") { ForEach(settings.builtinPresets) { p in Text(p.title).tag(p.key) } }
                    if !settings.customPresets.isEmpty {
                        Section("カスタム") { ForEach(settings.customPresets) { p in Text(p.title).tag(p.key) } }
                    }
                }
                .pickerStyle(.menu)
                Button { Task { await runSummary() } } label: { if isBusy { ProgressView() } else { Label("要約する", systemImage: "sparkles") } }
                .disabled(isBusy || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(alignment: .top, spacing: 12) {
                // 左：入力（ドロップ完全無効）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("入力テキスト"); Spacer()
                        Button { inputText = "" } label: { Label("クリア", systemImage: "xmark.circle") }
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inputText, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }
                    }
                    NonDroppableTextEditor(text: $inputText)
                        .frame(minHeight: 240)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }

                // 右：出力（ドロップ完全無効）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("要約結果"); Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(outputText, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }
                    }
                    NonDroppableTextEditor(text: $outputText)
                        .frame(minHeight: 240)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }
            }

            if let e = errorMessage { Text(e).foregroundStyle(.red) }
            Spacer()
        }
        .padding()
    }

    @MainActor
    private func runSummary() async {
        errorMessage = nil; isBusy = true; defer { isBusy = false }
        do {
            let system = settings.resolveSystemPromptForSelectedPreset()
            let out = try await SummarizerService.shared.summarize(inputText, systemPrompt: system)
            outputText = out
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 4) 履歴（読み込みは前回と同様）
private struct HistoryTab: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var records: [Record] = []
    @State private var filter: String = ""
    @State private var selected: Record?

    @State private var confirmClearAll = false
    @State private var confirmDeleteOne = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("検索（タイトル/本文）", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { confirmClearAll = true } label: { Label("全消去", systemImage: "trash") }
                }
                List(selection: $selected) {
                    ForEach(filteredRecords) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).bold()
                            Text(r.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .tag(r)
                    }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 280)

            VStack(alignment: .leading, spacing: 8) {
                if let r = selected {
                    HStack {
                        Text(r.title).font(.title3).bold()
                        Spacer()
                        Button(role: .destructive) { confirmDeleteOne = true } label: { Label("この記録を削除", systemImage: "trash") }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("書き起こし"); Spacer(); CopyButton(text: r.transcription) }
                            NonDroppableTextEditor(text: .constant(r.transcription))
                                .frame(minHeight: 220)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("要約"); Spacer(); CopyButton(text: r.summary) }
                            NonDroppableTextEditor(text: .constant(r.summary))
                                .frame(minHeight: 220)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        }
                    }
                } else {
                    Spacer(); Text("記録を選択してください").foregroundStyle(.secondary); Spacer()
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: filter) { _ in selectFirstIfNeeded() }
        .alert("全消去してもよろしいですか？", isPresented: $confirmClearAll) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { clearAll() }
        }
        .alert("この記録を削除しますか？", isPresented: $confirmDeleteOne) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { deleteSelected() }
        }
    }

    private var filteredRecords: [Record] {
        if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return records }
        let f = filter.lowercased()
        return records.filter { $0.title.lowercased().contains(f) || $0.preview.lowercased().contains(f) }
    }

    private func refresh() {
        records = loadRecords()
        selectFirstIfNeeded()
    }

    private func selectFirstIfNeeded() {
        if selected == nil { selected = filteredRecords.first }
    }

    private func clearAll() {
        do {
            let base = try karteBaseFolder()
            if FileManager.default.fileExists(atPath: base.path) {
                try FileManager.default.removeItem(at: base)
            }
            records.removeAll(); selected = nil
        } catch { print("[History] clearAll error: \(error)") }
    }

    private func deleteSelected() {
        guard let r = selected else { return }
        do { try FileManager.default.removeItem(at: r.folder) } catch { print("[History] delete error: \(error)") }
        refresh()
    }

    private func loadRecords() -> [Record] {
        var out: [Record] = []
        do {
            let base = try karteBaseFolder()
            let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for folder in items.sorted(by: { (a, b) in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad > bd
            }) where folder.hasDirectoryPath {
                let title = folder.lastPathComponent
                let trURL = folder.appendingPathComponent("transcription.txt")
                let smURL = folder.appendingPathComponent("summary.txt")
                let transcription = readText(trURL)
                let summary = readText(smURL)
                let preview = transcription.split(separator: "\n").prefix(2).joined(separator: "\n")
                out.append(Record(folder: folder, title: title, transcription: transcription, summary: summary, preview: preview))
            }
        } catch { print("[History] loadRecords error: \(error)") }
        return out
    }

    struct Record: Identifiable, Hashable {
        let id = UUID()
        let folder: URL
        let title: String
        let transcription: String
        let summary: String
        let preview: String
    }
}

// MARK: - 小物
private struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            #endif
        } label: { Label("コピー", systemImage: "doc.on.doc") }
    }
}

#if os(macOS)
// MARK: - macOS 専用：ドロップ無効 TextEditor（描画/レイアウト修正版）
private struct NonDroppableTextEditor: NSViewRepresentable {
    final class NonDroppableTextView: NSTextView {
        // すべてのドラッグ&ドロップを拒否して TextView に一切流さない
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) {}
    }

    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false // 背景はテキストビュー側で描画

        // TextView 本体
        let tv = NonDroppableTextView(frame: .zero)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.usesFindPanel = true

        // 視認性 & レイアウト
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)

        // スクロール & 折返し設定（NSTextView 正式プロパティ名に修正）
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        tv.string = text
        tv.delegate = context.coordinator

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NonDroppableTextView else { return }
        // 外部からの更新を確実に反映
        if tv.string != text {
            tv.string = text
        }
        // 幅追従を維持（親のサイズ変化時）
        tv.textContainer?.containerSize = NSSize(width: nsView.contentSize.width, height: .greatestFiniteMagnitude)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NonDroppableTextEditor
        init(_ parent: NonDroppableTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView {
                parent.text = tv.string
            }
        }
    }
}
#else
// iOS 等は通常の TextEditor（必要なら .onDrop でブロック）
private struct NonDroppableTextEditor: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text)
            .onDrop(of: [UTType.item.identifier], isTargeted: nil) { _ in true }
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

final class FloatingRecorderPaletteController {
    static let shared = FloatingRecorderPaletteController()
    private var window: NSPanel?

    private init() {
        // 表示/非表示の明示指示
        NotificationCenter.default.addObserver(
            forName: .init("palette.visibility.changed"),
            object: nil, queue: .main
        ) { [weak self] note in
            let visible = (note.userInfo as? [String: Any])?["visible"] as? Bool ?? true
            visible ? self?.show() : self?.hide()
        }
        // トグル
        NotificationCenter.default.addObserver(
            forName: .init("ui.togglePalette"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.toggle()
        }
    }

    /// パレット表示（作成含む）
    func show() {
        if Thread.isMainThread {
            show_impl()
        } else {
            DispatchQueue.main.async { [weak self] in self?.show_impl() }
        }
    }

    /// パレット非表示（しまう）
    func hide() {
        if Thread.isMainThread {
            hide_impl()
        } else {
            DispatchQueue.main.async { [weak self] in self?.hide_impl() }
        }
    }

    /// 出す/しまう切替
    func toggle() {
        if Thread.isMainThread {
            toggle_impl()
        } else {
            DispatchQueue.main.async { [weak self] in self?.toggle_impl() }
        }
    }

    // MARK: - 内部実装（必ずメインスレッド）
    private func show_impl() {
        if window == nil {
            let rect = NSRect(x: 120, y: 120, width: 280, height: 72)
            let panel = NSPanel(
                contentRect: rect,
                styleMask: [.titled, .utilityWindow], // ← .nonactivatingPanel を外す
                backing: .buffered,
                defer: false
            )
            panel.title = "Recorder"
            panel.identifier = NSUserInterfaceItemIdentifier("FloatingRecorderPalettePanel")
            panel.isReleasedWhenClosed = false      // ← 破棄しない（再利用）
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true

            // 必要なら × ボタンで「隠す」運用に統一（delegate設定がある場合）
            // panel.delegate = self (NSWindowDelegate実装側で windowShouldClose 参照)

            let host = NSHostingView(rootView: FloatingRecorderPalette())
            host.frame = NSRect(x: 0, y: 0, width: rect.width, height: rect.height)
            panel.contentView = host
            self.window = panel
        }
        // 非アクティブ時も前面化
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
        // 状況ログ（デバッグ用）
        #if DEBUG
        if let w = window {
            print("🟣 palette show -> visible=\(w.isVisible) key=\(w.isKeyWindow) id=\(w.identifier?.rawValue ?? "-")")
        }
        #endif
    }

    private func hide_impl() {
        guard let w = window else {
            #if DEBUG
            print("🟡 palette hide: window is nil")
            #endif
            return
        }
        w.orderOut(nil)
        #if DEBUG
        print("🟢 palette hide -> visible=\(w.isVisible) id=\(w.identifier?.rawValue ?? "-")")
        #endif
    }

    private func toggle_impl() {
        if let w = window, w.isVisible {
            hide_impl()
        } else {
            show_impl()
        }
    }
}
#endif
