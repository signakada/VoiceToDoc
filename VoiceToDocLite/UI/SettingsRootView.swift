import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var aiTestMessage: String = ""
    @State private var aiTesting: Bool = false

    var body: some View {
        TabView {
            SummaryTab()
                .environmentObject(settings)
                .tabItem { Label("要約", systemImage: "text.badge.plus") }

            SummarizerAITab(aiTestMessage: $aiTestMessage, aiTesting: $aiTesting)
                .environmentObject(settings)
                .tabItem { Label("要約AI", systemImage: "brain.head.profile") }

            WhisperTab()
                .environmentObject(settings)
                .tabItem { Label("音声", systemImage: "waveform") }

            MicrophoneTab()
                .environmentObject(settings)
                .tabItem { Label("マイク", systemImage: "mic") }

            MedicalDictionaryTab()
                .environmentObject(settings)
                .tabItem { Label("医療辞書", systemImage: "stethoscope") }
        }
        .padding()
        .alert(aiTestMessage, isPresented: Binding(get: { !aiTestMessage.isEmpty }, set: { _ in aiTestMessage = "" })) {
            Button("OK", role: .cancel) { aiTestMessage = "" }
        }
    }
}

// MARK: - 要約タブ（カスタムの編集/追加/削除が常に可能）
private struct SummaryTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var workingCustoms: [PresetItem] = []
    @State private var editing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("要約設定").font(.title2).bold()

            GroupBox("デフォルト要約（本文）") {
                TextEditor(text: Binding(
                    get: { settings.summaryInstructions },
                    set: { settings.setSummaryInstructions($0) }
                ))
                .frame(minHeight: 140)
            }

            GroupBox("使用する要約プリセット") {
                Picker("要約プリセット", selection: Binding(
                    get: {
                        let keys = settings.availablePresets.map { $0.key }
                        return keys.contains(settings.selectedPresetKey) ? settings.selectedPresetKey : settings.defaultBuiltinKey
                    },
                    set: { newKey in
                        settings.setSelectedPreset(key: newKey)
                    }
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
                .frame(maxWidth: 360)
            }

            GroupBox("カスタムプリセット") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            if !editing {
                                workingCustoms = settings.customPresets
                                editing = true
                            } else {
                                // 新規追加
                                let newKey = "custom.\(UUID().uuidString.prefix(8))"
                                workingCustoms.append(
                                    PresetItem(key: String(newKey),
                                               title: "新規プリセット",
                                               instructions: "このプリセットの要約指示文を入力してください。",
                                               kind: .custom)
                                )
                            }
                        } label: {
                            Label(editing ? "追加" : "編集を開始", systemImage: editing ? "plus.circle" : "square.and.pencil")
                        }

                        Spacer()

                        if editing {
                            Button("キャンセル", role: .cancel) {
                                editing = false
                                workingCustoms = []
                            }

                            Button("保存") {
                                // 保存：SSoTへ反映
                                settings.setCustomPresets(workingCustoms)

                                // もし選択中キーが削除されたらフォールバック
                                let keys = settings.availablePresets.map { $0.key }
                                if !keys.contains(settings.selectedPresetKey) {
                                    settings.setSelectedPreset(key: settings.defaultBuiltinKey)
                                }

                                editing = false
                                workingCustoms = []
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if editing {
                        // 双方向バインディングで確実に反映
                        if workingCustoms.isEmpty {
                            Text("カスタムプリセットはまだありません。『追加』で作成できます。")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                ForEach($workingCustoms) { $item in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            TextField("タイトル", text: $item.title)
                                                .textFieldStyle(.roundedBorder)
                                            Spacer(minLength: 8)
                                            Button(role: .destructive) {
                                                workingCustoms.removeAll { $0.key == item.key }
                                            } label: { Image(systemName: "trash") }
                                            .help("削除")
                                        }
                                        TextEditor(text: $item.instructions)
                                            .frame(minHeight: 100)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                            )
                                        Divider()
                                    }
                                }
                            }
                        }
                    } else {
                        // 読み取り表示（現在登録されているカスタム一覧）
                        if settings.customPresets.isEmpty {
                            Text("登録されたカスタムプリセットはありません。『編集を開始』→『追加』で作成できます。")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(settings.customPresets) { p in
                                    HStack {
                                        Text(p.title).font(.body)
                                        Spacer()
                                        Text(p.key).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .overlay(Divider(), alignment: .bottom)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .onAppear {
            // 編集開始時にロードする方式だが、初回に空表示を避けるため同期も可
            // workingCustoms = settings.customPresets
        }
    }
}

// MARK: - 要約AIタブ（詳細なエラーをアラート表示）
private struct SummarizerAITab: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var aiTestMessage: String
    @Binding var aiTesting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("要約AI 設定").font(.title2).bold()

            Picker("プロバイダ", selection: Binding(
                get: { settings.summarizerProvider },
                set: { settings.setSummarizerProvider($0) }
            )) {
                Text("Claude").tag("claude")
                Text("OpenAI").tag("openai")
                Text("Ollama").tag("ollama")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Group {
                if settings.summarizerProvider == "openai" {
                    OpenAIConfigSection(aiTestMessage: $aiTestMessage, aiTesting: $aiTesting)
                } else if settings.summarizerProvider == "claude" {
                    ClaudeConfigSection(aiTestMessage: $aiTestMessage, aiTesting: $aiTesting)
                } else {
                    OllamaConfigSection(aiTestMessage: $aiTestMessage, aiTesting: $aiTesting)
                }
            }

            Toggle(isOn: Binding(
                get: { settings.qwenThinkingEnabled },
                set: { settings.setQwenThinkingEnabled($0) }
            )) {
                Text("Qwen Thinking モードを有効にする（対応モデルのみ）")
            }
            .help("Qwen3 系の thinking 対応モデルで使用する場合にON（デフォルトはOFF）。")

            Spacer()
        }
    }
}

private struct OpenAIConfigSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var aiTestMessage: String
    @Binding var aiTesting: Bool

    @State private var openAIModel: String = "gpt-4o-mini"

    var body: some View {
        GroupBox("OpenAI 設定") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("APIキー（sk-...）", text: Binding(
                    get: { settings.openAIKey },
                    set: { settings.setOpenAIKey($0) }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Text("モデル名").frame(width: 90, alignment: .leading)
                    TextField("gpt-4o-mini", text: $openAIModel)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button {
                        Task { await testOpenAI() }
                    } label: {
                        if aiTesting { ProgressView() } else { Text("接続確認") }
                    }
                    .disabled(aiTesting)

                    Text("OpenAI API に接続できるかを確認します（/v1/models）。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func testOpenAI() async {
        aiTesting = true
        defer { aiTesting = false }
        do {
            try await settings.testOpenAIConnection()
            aiTestMessage = "OpenAI に接続できました。"
        } catch {
            aiTestMessage = "OpenAI 接続エラー: \(error.localizedDescription)"
        }
    }
}

private struct ClaudeConfigSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var aiTestMessage: String
    @Binding var aiTesting: Bool

    @State private var claudeModel: String = "claude-3-7-sonnet-20250219"

    var body: some View {
        GroupBox("Claude 設定") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("APIキー（sk-ant-...）", text: Binding(
                    get: { settings.claudeKey },
                    set: { settings.setClaudeKey($0) }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Text("モデル名").frame(width: 90, alignment: .leading)
                    TextField("claude-3-7-sonnet-20250219", text: $claudeModel)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button {
                        Task { await testClaude() }
                    } label: {
                        if aiTesting { ProgressView() } else { Text("接続確認") }
                    }
                    .disabled(aiTesting)

                    Text("Anthropic API に接続できるかを確認します（/v1/models）。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func testClaude() async {
        aiTesting = true
        defer { aiTesting = false }
        do {
            try await settings.testClaudeConnection()
            aiTestMessage = "Claude に接続できました。"
        } catch {
            aiTestMessage = "Claude 接続エラー: \(error.localizedDescription)"
        }
    }
}

private struct OllamaConfigSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var aiTestMessage: String
    @Binding var aiTesting: Bool

    var body: some View {
        GroupBox("Ollama 設定") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ホスト").frame(width: 90, alignment: .leading)
                    TextField("http://127.0.0.1:11434", text: Binding(
                        get: { settings.ollamaHost },
                        set: { settings.setOllamaHost($0) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("モデル更新") {
                        Task {
                            do {
                                try await refresh()
                            } catch {
                                // アラート表示
                                aiTestMessage = "Ollama モデル取得エラー: \(error.localizedDescription)"
                            }
                        }
                    }
                }

                HStack {
                    Text("モデル").frame(width: 90, alignment: .leading)
                    Picker("モデル", selection: Binding(
                        get: { settings.ollamaSelectedModel },
                        set: { settings.setOllamaSelectedModel($0) }
                    )) {
                        ForEach(settings.ollamaModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .frame(maxWidth: 360)
                }

                HStack {
                    Button {
                        Task { await test() }
                    } label: {
                        if aiTesting { ProgressView() } else { Text("接続確認") }
                    }
                    .disabled(aiTesting)

                    Text("Ollama API に接続できるか確認します（/api/tags）。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        .task {
            if settings.ollamaModels.isEmpty {
                _ = try? await refresh()
            }
        }
    }

    private func refresh() async throws {
        do {
            await settings.refreshOllamaModels()
        } catch {
            throw error
        }
    }

    private func test() async {
        aiTesting = true
        defer { aiTesting = false }
        do {
            try await settings.testOllamaConnection()
            aiTestMessage = "Ollama に接続できました。"
        } catch {
            aiTestMessage = "Ollama 接続エラー: \(error.localizedDescription)"
        }
    }
}

// MARK: - Whisper
private struct WhisperTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var isFolderImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音声設定").font(.title2).bold()

            Picker("強制言語", selection: Binding(
                get: { settings.whisperForceLanguage },
                set: { settings.setWhisperForceLanguage($0) }
            )) {
                Text("自動判定").tag("auto")
                Text("日本語（ja）").tag("ja")
                Text("英語（en）").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Picker("Whisper モデル", selection: Binding(
                get: { settings.whisperModelPreference },
                set: { settings.setWhisperModelPreference($0) }
            )) {
                Text("large-v3-turbo").tag("large-v3-turbo")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            Toggle(isOn: Binding(
                get: { settings.purgeOnQuit },
                set: { settings.setPurgeOnQuit($0) }
            )) {
                Text("アプリ終了時に録音（音声ファイル）のみ自動消去")
            }
            .help("アプリ終了時に『書類/音声カルテ』配下の .wav/.m4a/.mp3 などの音声ファイルだけを削除します。転写・要約テキストは残ります。")

            // 保存先セクション
            // 保存先セクション
            GroupBox(label: Label("保存先", systemImage: "externaldrive").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { isFolderImporterPresented = true } label: {
                            Label("保存先フォルダを選択…", systemImage: "folder")
                        }
                        if let url = settings.resolvedStorageBaseURL {
                            Text(url.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未設定（アプリ内の書類フォルダを使用）")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.resolvedStorageBaseURL != nil {
                            Button(role: .destructive) { settings.clearStorageBaseURL() } label: {
                                Label("解除", systemImage: "trash")
                            }
                        }
                    }
                    Text("ここで選んだフォルダ配下に『音声カルテ/日付時刻』を作成して保存します。アクセス許可はブックマークとして保存され、次回以降も有効です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fileImporter(
                isPresented: $isFolderImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let u = urls.first {
                        // 念のため UI 側でもアクセス開始（Settings 側で再度開始するので二重でも安全）
                        let did = u.startAccessingSecurityScopedResource()
                        defer { if did { u.stopAccessingSecurityScopedResource() } }
                        settings.setStorageBaseURL(u)
                    }
                case .failure(let e):
                    print("[Settings] folder pick failed: \(e.localizedDescription)")
                }
            }
            Spacer()
        }
    }
}

// MARK: - マイク
private struct MicrophoneTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedID: String = UserDefaults.standard.string(forKey: "selected_microphone_unique_id") ?? ""
    @State private var selectedName: String = UserDefaults.standard.string(forKey: "selected_microphone_name") ?? "（システム既定）"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("マイク設定").font(.title2).bold()

            HStack(spacing: 12) {
                Button {
                    settings.refreshMicrophones()
                    // デバイス一覧更新後、保存値が存在しない場合は既定に戻す
                    let saved = UserDefaults.standard.string(forKey: "selected_microphone_unique_id") ?? ""
                    if saved.isEmpty || settings.availableMicrophones.first(where: { $0.id == saved }) == nil {
                        selectedID = ""
                        selectedName = "（システム既定）"
                        UserDefaults.standard.removeObject(forKey: "selected_microphone_unique_id")
                        UserDefaults.standard.removeObject(forKey: "selected_microphone_name")
                    }
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }

                if settings.availableMicrophones.isEmpty {
                    Text("マイクが見つかりませんでした").foregroundStyle(.secondary)
                }

                Spacer()

                // 既定に戻す
                Button {
                    selectedID = ""
                    selectedName = "（システム既定）"
                    UserDefaults.standard.removeObject(forKey: "selected_microphone_unique_id")
                    UserDefaults.standard.removeObject(forKey: "selected_microphone_name")
                } label: {
                    Label("既定に戻す", systemImage: "arrow.uturn.backward")
                }
            }

            HStack(spacing: 12) {
                Text("マイク").frame(width: 60, alignment: .leading)
                Picker("マイク", selection: Binding(
                    get: {
                        // 保存値が一覧に無い場合は空（既定）にする
                        if !selectedID.isEmpty,
                           settings.availableMicrophones.first(where: { $0.id == selectedID }) == nil {
                            return ""
                        }
                        return selectedID
                    },
                    set: { newValue in
                        selectedID = newValue
                        // 名前も一緒に保存
                        if let mic = settings.availableMicrophones.first(where: { $0.id == newValue }) {
                            selectedName = mic.name
                            UserDefaults.standard.set(newValue, forKey: "selected_microphone_unique_id")
                            UserDefaults.standard.set(mic.name, forKey: "selected_microphone_name")
                        } else {
                            selectedName = "（システム既定）"
                            UserDefaults.standard.removeObject(forKey: "selected_microphone_unique_id")
                            UserDefaults.standard.removeObject(forKey: "selected_microphone_name")
                        }
                    }
                )) {
                    Text("（システム既定を使用）").tag("")
                    ForEach(settings.availableMicrophones, id: \.id) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("現在の選択: \(selectedName)", systemImage: "mic.fill")
                Text("""
                ・選択内容は即時保存され、次回起動時および次回の録音開始時に自動で適用されます。
                ・選んだマイクが見つからない場合は、システム既定の入力にフォールバックします。
                """)
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        // 例）既存の「要約AI」「マイク」等の並びに
        HotKeySettingsTab()
            .tabItem { Label("ホットキー", systemImage: "keyboard") }
        .onAppear {
            // 初期表示時に保存内容を反映
            let savedID = UserDefaults.standard.string(forKey: "selected_microphone_unique_id") ?? ""
            let savedName = UserDefaults.standard.string(forKey: "selected_microphone_name") ?? "（システム既定）"
            selectedID = savedID
            selectedName = savedName

            // 一覧が空なら最初に読み込む
            if settings.availableMicrophones.isEmpty {
                settings.refreshMicrophones()
            }
        }
    }
}

// MARK: - 医療辞書
private struct MedicalDictionaryTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var newTerm: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("医療辞書").font(.title2).bold()

            HStack {
                TextField("用語を追加（例：ハロペリドール）", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !term.isEmpty {
                        settings.addMedicalTerm(term)
                        newTerm = ""
                    }
                } label: { Label("追加", systemImage: "plus.circle") }
            }

            if settings.medicalTerms.isEmpty {
                Text("登録された用語はありません。").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(settings.medicalTerms) { item in
                        HStack {
                            TextField("用語", text: Binding(
                                get: { item.term },
                                set: { settings.updateMedicalTerm(old: item.term, new: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Spacer()
                            Button(role: .destructive) {
                                settings.removeMedicalTerm(item.term)
                            } label: { Image(systemName: "trash") }
                            .help("削除")
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 220)
            }

            Spacer()
        }
    }
}
