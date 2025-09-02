import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    // 録音状態は MainView と同じ通知（audioCapture.state）で同期
    @State private var isRecording = false

    // 画面ペイン
    @State private var isSummarizing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {

            // ===== 上部コントロール：録音トグル + 要約実行 =====
            HStack(spacing: 12) {
                // 録音トグル（中央集約の ui.toggleRecord を叩く）
                Button {
                    NotificationCenter.default.post(name: .init("ui.toggleRecord"), object: nil)
                } label: {
                    if isRecording {
                        Label("停止", systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("録音開始", systemImage: "record.circle")
                    }
                }
                .keyboardShortcut("r", modifiers: [.option, .command]) // ⌥⌘R と視覚的一致

                Spacer()

                // 要約プリセット（Settings と連動）
                Picker("プリセット", selection: Binding(
                    get: { settings.selectedPresetKey },
                    set: { settings.setSelectedPreset(key: $0) }
                )) {
                    Section("デフォルト（内蔵）") {
                        ForEach(settings.builtinPresets) { p in
                            Text(p.title).tag(p.key)
                        }
                    }
                    if !settings.customPresets.isEmpty {
                        Section("カスタム") {
                            ForEach(settings.customPresets) { p in
                                Text(p.title).tag(p.key)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)

                Button {
                    Task { await runSummarize() }
                } label: {
                    if isSummarizing {
                        ProgressView()
                    } else {
                        Label("要約する", systemImage: "sparkles")
                    }
                }
                .disabled(isSummarizing || appState.lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // ===== 下部：左右ペイン（左＝書き起こし、右＝要約） =====
            HStack(alignment: .top, spacing: 12) {

                // 左ペイン：書き起こし
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("書き起こし").font(.headline)
                        Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.lastOutput, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }

                        Button {
                            appState.lastOutput = ""
                        } label: { Label("クリア", systemImage: "xmark.circle") }
                    }

                    // ドロップはこのタブでは無効（タブ2で取り込み）
                    // 【修正】appState.lastOutputに直接バインド
                    NonDroppableTextEditor(text: $appState.lastOutput)
                        .frame(minHeight: 240)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }

                // 右ペイン：要約
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("要約").font(.headline)
                        Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.lastSummary, forType: .string)
                            #endif
                        } label: { Label("コピー", systemImage: "doc.on.doc") }
                        
                        Button {
                            appState.lastSummary = ""
                        } label: { Label("クリア", systemImage: "xmark.circle") }
                    }

                    // 【修正】appState.lastSummaryに直接バインド
                    NonDroppableTextEditor(text: $appState.lastSummary)
                        .frame(minHeight: 240)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }
            }

            if let msg = errorMessage {
                Text(msg).foregroundStyle(.red)
            }

        Spacer()
    }
    .padding()
    .onAppear {
        // UIがロードされたらAppStateの最新データを反映
        // 【修正】ここは削除されました。
    }

    // === 状態同期（録音） ===
    .onReceive(NotificationCenter.default.publisher(for: .init("audioCapture.state"))) { note in
        if let rec = (note.userInfo as? [String: Any])?["recording"] as? Bool {
            isRecording = rec
        }
    }

    // === 転写開始の合図（.audioFileReady 受信時に「転写中＝青」を指示） ===
    .onReceive(NotificationCenter.default.publisher(for: .init("audioFileReady"))) { _ in
        NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "transcribing"])
    }
    
    // 【削除】AppStateのlastOutput変更を検知してUIを更新するロジックは、直接バインディングで不要になりました。
    
    }

    // ===== 要約の実体 =====
    @MainActor
    private func runSummarize() async {
        guard !isSummarizing else { return }
        guard !appState.lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        errorMessage = nil
        isSummarizing = true

        // パレットへ「要約中＝紫」通知
        NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "summarizing"])

        defer { isSummarizing = false }
        do {
            let sys = settings.resolveSystemPromptForSelectedPreset()
            let out = try await SummarizerService.shared.summarize(appState.lastOutput, systemPrompt: sys)
            appState.lastSummary = out

            // 自動コピー（要約完了時）
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out, forType: .string)
            #endif

            // パレットへ「完了＝緑（10秒）」通知
            NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "done"])

            // 【再追加】要約結果をファイルに保存する
            if let folder = appState.lastSessionFolder {
                let fileURL = folder.appendingPathComponent("summary.txt")
                try out.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                print("[ContentView] 📝 saved summary to \(fileURL.path)")
            }

        } catch {
            errorMessage = error.localizedDescription
            // 失敗時は色を戻す（任意：赤系でもOK）
            NotificationCenter.default.post(name: .init("job.phase"), object: nil, userInfo: ["phase": "idle"])
        }
    }
}

#if os(macOS)
// macOS: ドロップ全面禁止の TextEditor 実装（Tab2 で D&D を受けるため）
private struct NonDroppableTextEditor: NSViewRepresentable {
    final class NonDroppableTextView: NSTextView {
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
        scroll.drawsBackground = false

        let tv = NonDroppableTextView(frame: .zero)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.usesFindPanel = true

        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)

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
        if tv.string != text { tv.string = text }
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
// iOS など
private struct NonDroppableTextEditor: View {
    @Binding var text: String
    var body: some View { TextEditor(text: $text) }
}
#endif
