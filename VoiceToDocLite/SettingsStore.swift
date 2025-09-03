import Foundation
import Combine
import AVFoundation

// === 共通DTO：プリセット（内蔵/カスタムを統一表現） ==========================
public struct PresetItem: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case builtin, custom }
    public var id: String { key }
    public let key: String          // 内蔵: SummaryPreset.rawValue / カスタム: 任意キー
    public var title: String        // 表示名
    public var instructions: String // プロンプト本文
    public let kind: Kind
}

// === 医療辞書（簡易版）：1用語=文字列 ==========================================
public struct MedicalTerm: Codable, Identifiable, Equatable {
    public var id: String { term }
    public var term: String
}

public final class SettingsStore: ObservableObject {

    // MARK: - UserDefaults Keys
    private struct K {
        // Whisper / 音声系
        static let whisperModelPreference  = "whisper_model_preference"
        static let whisperForceLanguage    = "whisper_force_language"

        // 要約プリセット
        static let selectedSummaryPreset   = "selected_summary_preset"
        static let summaryInstructions     = "summary_instructions"
        static let customPresetsData       = "custom_presets_data"

        // 要約AI
        static let summarizerProvider      = "summarizer_provider"         // "openai" | "claude" | "ollama"
        static let openAIKey               = "openai_api_key"
        static let claudeKey               = "claude_api_key"
        static let ollamaHost              = "ollama_host"                  // http://127.0.0.1:11434
        static let ollamaSelectedModel     = "ollama_selected_model"
        static let ollamaModelsCache       = "ollama_models_cache"          // [String]
        static let qwenThinkingEnabled     = "qwen_thinking_enabled"        // Bool

        // マイク
        static let selectedMicID           = "selected_microphone_unique_id"

        // 医療辞書
        static let medicalDictionary       = "medical_dictionary_terms"     // [String]

        // 保存先（セキュリティスコープ付きブックマーク）
        static let storageBaseBookmark     = "storage_base_bookmark"        // Data
    }

    // MARK: - Defaults
    private struct Defaults {
        // Whisper
        static let whisperModelPreference  = "large-v3-turbo"
        static let whisperForceLanguage    = "auto"

        // 要約（本文デフォルト）
        static let summaryInstructions     = "要約をお願いします。重要点を箇条書きで簡潔に。重複は避けてください。"

        // 要約AI
        static let summarizerProvider      = "claude" // 既定は Claude とする（ご要望により auto 削除）
        static let openAIKey               = ""
        static let claudeKey               = ""
        static let ollamaHost              = "http://127.0.0.1:11434"
        static let ollamaSelectedModel     = ""
        static let ollamaModelsCache: [String] = []
        static let qwenThinkingEnabled     = false

        // マイク
        static let selectedMicID           = ""

        // 医療辞書
        static let medicalDictionary: [String] = []
    }

    // 既定値登録
    private static func registerDefaults() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            K.whisperModelPreference : Defaults.whisperModelPreference,
            K.whisperForceLanguage   : Defaults.whisperForceLanguage,
            K.summaryInstructions    : Defaults.summaryInstructions,

            K.summarizerProvider     : Defaults.summarizerProvider,
            K.openAIKey              : Defaults.openAIKey,
            K.claudeKey              : Defaults.claudeKey,
            K.ollamaHost             : Defaults.ollamaHost,
            K.ollamaSelectedModel    : Defaults.ollamaSelectedModel,
            K.ollamaModelsCache      : Defaults.ollamaModelsCache,
            K.qwenThinkingEnabled    : Defaults.qwenThinkingEnabled,

            K.selectedMicID          : Defaults.selectedMicID,

            K.medicalDictionary      : Defaults.medicalDictionary,
        ])
    }

    private let ud = UserDefaults.standard

    // MARK: - Published (UI バインド)

    // Whisper
    @Published public var whisperModelPreference: String
    @Published public var whisperForceLanguage: String

    // 要約（デフォルト本文）
    @Published public var summaryInstructions: String

    // プリセット選択キー
    @Published public var selectedPresetKey: String

    // 要約AI（プロバイダ / キー / Ollama）
    @Published public var summarizerProvider: String            // "openai" | "claude" | "ollama"
    @Published public var openAIKey: String
    @Published public var claudeKey: String
    @Published public var ollamaHost: String
    @Published public var ollamaSelectedModel: String
    @Published public var ollamaModels: [String] = []
    @Published var qwenThinkingEnabled: Bool = false
    
    // マイク
    @Published public var availableMicrophones: [(id: String, name: String)] = []
    @Published public var selectedMicID: String

    // 医療辞書
    @Published public var medicalTerms: [MedicalTerm] = []

    // アプリ終了時に音声だけを消去
    @Published public var purgeOnQuit: Bool = UserDefaults.standard.bool(forKey: "purge_on_quit")

    // === 保存先（ユーザー選択フォルダ：セキュリティスコープ付きブックマーク） ===
    @Published public var storageBaseBookmark: Data? = UserDefaults.standard.data(forKey: K.storageBaseBookmark)

    /// 選択済み保存先のURL（ブックマークを解決）。UI表示やラベル表示用。
    /// 実際のファイル書き込み時に startAccessingSecurityScopedResource() を呼ぶのは呼び出し側で行う。
    public var resolvedStorageBaseURL: URL? {
        guard let data = storageBaseBookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return url
        } catch {
            print("[Settings] resolve storage bookmark failed: \(error)")
            return nil
        }
    }

    public func setStorageBaseURL(_ url: URL) {
        // セキュリティスコープ開始（Sandbox 必須）
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            // 書込可能なブックマークを生成
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            self.storageBaseBookmark = data
            ud.set(data, forKey: K.storageBaseBookmark)
            print("[Settings] storage base saved: \(url.path)")
        } catch {
            print("[Settings] save storage base bookmark failed: \(error)")
        }
    }

    public func clearStorageBaseURL() {
        self.storageBaseBookmark = nil
        ud.removeObject(forKey: K.storageBaseBookmark)
    }

    // MARK: - Presets（SSoT 読み取り）
    public var builtinPresets: [PresetItem] {
        PresetStore.shared.all.map { p in
            PresetItem(
                key: p.rawValue,
                title: p.title,
                instructions: p.prompt,
                kind: .builtin
            )
        }
    }
    public var customPresets: [PresetItem] {
        struct CustomDTO: Codable { var key: String; var title: String; var instructions: String }
        guard let data = ud.data(forKey: K.customPresetsData),
              let arr = try? JSONDecoder().decode([CustomDTO].self, from: data) else {
            return []
        }
        return arr.map { PresetItem(key: $0.key, title: $0.title, instructions: $0.instructions, kind: .custom) }
    }
    public var availablePresets: [PresetItem] { builtinPresets + customPresets }
    public var defaultBuiltinKey: String { PresetStore.shared.defaultPreset.rawValue }

    // MARK: - Init
    public init() {
        Self.registerDefaults()

        // Whisper
        self.whisperModelPreference = ud.string(forKey: K.whisperModelPreference) ?? Defaults.whisperModelPreference
        self.whisperForceLanguage   = ud.string(forKey: K.whisperForceLanguage)   ?? Defaults.whisperForceLanguage

        // 要約
        self.summaryInstructions    = ud.string(forKey: K.summaryInstructions)    ?? Defaults.summaryInstructions
        self.selectedPresetKey      = ud.string(forKey: K.selectedSummaryPreset)  ?? PresetStore.shared.defaultPreset.rawValue

        // 要約AI
        self.summarizerProvider     = ud.string(forKey: K.summarizerProvider)     ?? Defaults.summarizerProvider
        self.openAIKey              = ud.string(forKey: K.openAIKey)              ?? Defaults.openAIKey
        self.claudeKey              = ud.string(forKey: K.claudeKey)              ?? Defaults.claudeKey
        self.ollamaHost             = ud.string(forKey: K.ollamaHost)             ?? Defaults.ollamaHost
        self.ollamaSelectedModel    = ud.string(forKey: K.ollamaSelectedModel)    ?? Defaults.ollamaSelectedModel
        self.qwenThinkingEnabled    = ud.object(forKey: K.qwenThinkingEnabled) as? Bool ?? Defaults.qwenThinkingEnabled
        if let cached = ud.array(forKey: K.ollamaModelsCache) as? [String] {
            self.ollamaModels = cached
        }

        // マイク
        self.selectedMicID          = ud.string(forKey: K.selectedMicID)          ?? Defaults.selectedMicID
        self.refreshMicrophones() // 初期一覧

        // 医療辞書
        if let arr = ud.array(forKey: K.medicalDictionary) as? [String] {
            self.medicalTerms = arr.map { MedicalTerm(term: $0) }
        }
    }

    // MARK: - Setters（Whisper / 要約 / プリセット）
    public func setWhisperModelPreference(_ modelId: String) {
        ud.set(modelId, forKey: K.whisperModelPreference)
        whisperModelPreference = modelId
    }
    public func setWhisperForceLanguage(_ lang: String) {
        ud.set(lang, forKey: K.whisperForceLanguage)
        whisperForceLanguage = lang
    }
    public func setSummaryInstructions(_ text: String) {
        ud.set(text, forKey: K.summaryInstructions)
        summaryInstructions = text
    }
    public func setSelectedPreset(key: String) {
        ud.set(key, forKey: K.selectedSummaryPreset)
        selectedPresetKey = key
    }
    public func setCustomPresets(_ items: [PresetItem]) {
        struct CustomDTO: Codable { var key: String; var title: String; var instructions: String }
        let customs = items.filter { $0.kind == .custom }.map { CustomDTO(key: $0.key, title: $0.title, instructions: $0.instructions) }
        if let data = try? JSONEncoder().encode(customs) {
            ud.set(data, forKey: K.customPresetsData)
        }
        objectWillChange.send()
    }

    // MARK: - 要約AI Setters / Actions
    public func setSummarizerProvider(_ provider: String) {
        ud.set(provider, forKey: K.summarizerProvider)
        summarizerProvider = provider
    }
    public func setOpenAIKey(_ key: String) {
        ud.set(key, forKey: K.openAIKey)
        openAIKey = key
    }
    public func setClaudeKey(_ key: String) {
        ud.set(key, forKey: K.claudeKey)
        claudeKey = key
    }
    public func setOllamaHost(_ host: String) {
        ud.set(host, forKey: K.ollamaHost)
        ollamaHost = host
    }
    public func setOllamaSelectedModel(_ model: String) {
        ud.set(model, forKey: K.ollamaSelectedModel)
        ollamaSelectedModel = model
    }
    public func setQwenThinkingEnabled(_ enabled: Bool) {
        if qwenThinkingEnabled == enabled { return }
        qwenThinkingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "qwen_thinking_enabled")
        objectWillChange.send()
    }

    /// Ollama: /api/tags からモデル一覧を取得してキャッシュ
    @MainActor
    public func refreshOllamaModels() async {
        guard let url = URL(string: "\(ollamaHost)/api/tags") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // 形式: { "models": [ { "name": "llama3:latest", ... }, ... ] }
            struct Tag: Decodable { let name: String }
            struct Resp: Decodable { let models: [Tag] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            let names = decoded.models.map { $0.name }
            self.ollamaModels = names
            ud.set(names, forKey: K.ollamaModelsCache)
            // 既存選択が消えた場合は先頭にフォールバック
            if !names.contains(self.ollamaSelectedModel), let first = names.first {
                setOllamaSelectedModel(first)
            }
        } catch {
            // 失敗時は何もしない（UIでアラート表示想定）
        }
    }

    // OpenAI 接続確認（詳細ログ付き）
    public func testOpenAIConnection() async throws {
        guard !openAIKey.isEmpty else {
            throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "APIキーが未設定です (OpenAI)"])
        }
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw NSError(domain: "OpenAI", code: -2, userInfo: [NSLocalizedDescriptionKey: "URL 構成エラー (OpenAI)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("VoiceToDocLite/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(body decode failed)"
                throw NSError(
                    domain: "OpenAI",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)\n\(body)"]
                )
            }
        } catch let e as URLError {
            throw NSError(domain: "OpenAI", code: e.errorCode, userInfo: [NSLocalizedDescriptionKey: "URLError(\(e.errorCode)): \(e.localizedDescription)"])
        } catch {
            throw NSError(domain: "OpenAI", code: -999, userInfo: [NSLocalizedDescriptionKey: "不明なエラー: \(error.localizedDescription)"])
        }
    }

    // Claude 接続確認（詳細ログ付き）
    public func testClaudeConnection() async throws {
        guard !claudeKey.isEmpty else {
            throw NSError(domain: "Claude", code: -1, userInfo: [NSLocalizedDescriptionKey: "APIキーが未設定です (Claude)"])
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            throw NSError(domain: "Claude", code: -2, userInfo: [NSLocalizedDescriptionKey: "URL 構成エラー (Claude)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(claudeKey, forHTTPHeaderField: "x-api-key")
        req.setValue("VoiceToDocLite/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(body decode failed)"
                throw NSError(
                    domain: "Claude",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)\n\(body)"]
                )
            }
        } catch let e as URLError {
            throw NSError(domain: "Claude", code: e.errorCode, userInfo: [NSLocalizedDescriptionKey: "URLError(\(e.errorCode)): \(e.localizedDescription)"])
        } catch {
            throw NSError(domain: "Claude", code: -999, userInfo: [NSLocalizedDescriptionKey: "不明なエラー: \(error.localizedDescription)"])
        }
    }

    // Ollama 接続確認（詳細ログ付き）
    public func testOllamaConnection() async throws {
        guard let url = URL(string: "\(ollamaHost)/api/tags") else {
            throw NSError(domain: "Ollama", code: -2, userInfo: [NSLocalizedDescriptionKey: "ホストURLが不正です (Ollama)"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("VoiceToDocLite/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(body decode failed)"
                throw NSError(
                    domain: "Ollama",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)\n\(body)"]
                )
            }
        } catch let e as URLError {
            throw NSError(domain: "Ollama", code: e.errorCode, userInfo: [NSLocalizedDescriptionKey: "URLError(\(e.errorCode)): \(e.localizedDescription)"])
        } catch {
            throw NSError(domain: "Ollama", code: -999, userInfo: [NSLocalizedDescriptionKey: "不明なエラー: \(error.localizedDescription)"])
        }
    }

    /// ネットワーク自己診断（HTTPS/HTTP 基本疎通）
    public func networkSelfTest() async -> String {
        struct Probe { let name: String; let url: String }
        let probes: [Probe] = [
            .init(name: "Apple", url: "https://www.apple.com/library/test/success.html"),
            .init(name: "OpenAI models", url: "https://api.openai.com/v1/models"),
            .init(name: "Anthropic models", url: "https://api.anthropic.com/v1/models"),
        ]
        var lines: [String] = []
        for p in probes {
            guard let u = URL(string: p.url) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 10
            if p.url.contains("openai.com") && !openAIKey.isEmpty {
                req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            }
            if p.url.contains("anthropic.com") && !claudeKey.isEmpty {
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue(claudeKey, forHTTPHeaderField: "x-api-key")
            }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    lines.append("[OK] \(p.name) HTTP \(http.statusCode)")
                } else {
                    lines.append("[OK] \(p.name)")
                }
            } catch {
                lines.append("[NG] \(p.name): \(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - マイク一覧・選択
    public func refreshMicrophones() {
        #if os(macOS)
        let devices = AVCaptureDevice.devices(for: .audio)
        self.availableMicrophones = devices.map { (id: $0.uniqueID, name: $0.localizedName) }
        // 初期選択
        if selectedMicID.isEmpty, let first = availableMicrophones.first?.id {
            setSelectedMicID(first)
        }
        #else
        self.availableMicrophones = []
        #endif
    }
    public func setSelectedMicID(_ id: String) {
        ud.set(id, forKey: K.selectedMicID)
        selectedMicID = id
    }

    // MARK: - 医療辞書
    public func addMedicalTerm(_ term: String) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !medicalTerms.contains(where: { $0.term == term }) {
            medicalTerms.append(MedicalTerm(term: term))
            saveMedicalTerms()
        }
    }
    public func updateMedicalTerm(old: String, new: String) {
        if let idx = medicalTerms.firstIndex(where: { $0.term == old }) {
            medicalTerms[idx].term = new
            saveMedicalTerms()
        }
    }
    public func removeMedicalTerm(_ term: String) {
        medicalTerms.removeAll { $0.term == term }
        saveMedicalTerms()
    }
    private func saveMedicalTerms() {
        let arr = medicalTerms.map { $0.term }
        ud.set(arr, forKey: K.medicalDictionary)
        objectWillChange.send()
    }

    // MARK: - 要約プロンプト解決（SSoT）
    public func resolveSystemPromptForSelectedPreset() -> String {
        if let b = builtinPresets.first(where: { $0.key == selectedPresetKey }) {
            return b.instructions
        }
        if let c = customPresets.first(where: { $0.key == selectedPresetKey }) {
            return c.instructions
        }
        return summaryInstructions
    }

    // MARK: - その他
    public func setPurgeOnQuit(_ v: Bool) {
        purgeOnQuit = v
        UserDefaults.standard.set(v, forKey: "purge_on_quit")
    }
}
