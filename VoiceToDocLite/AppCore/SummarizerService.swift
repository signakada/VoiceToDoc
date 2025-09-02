import Foundation

// MARK: - Summarizer Service (Providers: OpenAI / Claude / Ollama)
final class SummarizerService {
    static let shared = SummarizerService()
    private init() {}

    // UserDefaults Keys (must match SettingsStore)
    private enum K {
        static let provider = "summarizer_provider"             // "openai" | "claude" | "ollama"
        static let openAIKey = "openai_api_key"
        static let claudeKey = "claude_api_key"
        static let ollamaHost = "ollama_host"                   // http://127.0.0.1:11434
        static let ollamaModel = "ollama_selected_model"
        static let openAIModel = "summarizer_openai_model"      // optional (fallback local default)
        static let claudeModel = "summarizer_claude_model"      // optional (fallback local default)
        static let qwenThinking = "qwen_thinking_enabled"       // Bool
    }

    // MARK: - Public API
    /// 指定テキストを現在の設定で要約
    func summarize(_ text: String, systemPrompt: String) async throws -> String {
        let provider = UserDefaults.standard.string(forKey: K.provider) ?? "claude"
        log("🧭 [SummarizerService] provider=\(provider)")
        switch provider {
        case "openai":
            return try await summarizeWithOpenAI(text: text, system: systemPrompt)
        case "ollama":
            return try await summarizeWithOllama(text: text, system: systemPrompt)
        default: // "claude"
            return try await summarizeWithClaude(text: text, system: systemPrompt)
        }
    }

    // MARK: - OpenAI
    private func summarizeWithOpenAI(text: String, system: String) async throws -> String {
        let (apiKey, src) = readKey(names: [K.openAIKey, "OPENAI_API_KEY"]) // defaults → env
        guard let apiKey, !apiKey.isEmpty else { throw err("OpenAI", -1, "APIキーが未設定です: OPENAI_API_KEY") }
        log("🔑 [OpenAI] key source=\(src)")

        let model = UserDefaults.standard.string(forKey: K.openAIModel) ?? "gpt-4o-mini"
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Msg: Codable { let role: String; let content: String }
        struct Body: Codable { let model: String; let messages: [Msg]; let temperature: Double }
        let body = Body(model: model, messages: [Msg(role: "system", content: system), Msg(role: "user", content: text)], temperature: 0.0)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data, vendor: "OpenAI")

        // parse
        struct Choice: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message?
            let delta: Message?
        }
        struct Resp: Codable { let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let content = decoded.choices.first?.message?.content ?? decoded.choices.first?.delta?.content
        return content ?? ""
    }

    // MARK: - Claude (Anthropic)
    private func summarizeWithClaude(text: String, system: String) async throws -> String {
        let (apiKey, src) = readKey(names: [K.claudeKey, "CLAUDE_API_KEY"]) // defaults → env
        guard let apiKey, !apiKey.isEmpty else { throw err("Claude", -1, "APIキーが未設定です: CLAUDE_API_KEY") }
        log("🔑 [Claude] key source=\(src)")

        let model = UserDefaults.standard.string(forKey: K.claudeModel) ?? "claude-3-7-sonnet-20250219"
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        struct Msg: Codable { let role: String; let content: String }
        struct Body: Codable { let model: String; let max_tokens: Int; let system: String?; let messages: [Msg] }
        let body = Body(model: model, max_tokens: 2048, system: system, messages: [Msg(role: "user", content: text)])
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data, vendor: "Claude")

        struct TextBlock: Codable { let text: String? }
        struct Content: Codable { let type: String; let text: String? }
        struct Message: Codable { let content: [Content] }
        struct Resp: Codable { let content: [Content] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let textOut = decoded.content.compactMap { $0.text }.joined(separator: "\n")
        return textOut
    }

    // MARK: - Ollama (local)
    private func summarizeWithOllama(text: String, system: String) async throws -> String {
        let host = UserDefaults.standard.string(forKey: K.ollamaHost) ?? "http://127.0.0.1:11434"
        let model = UserDefaults.standard.string(forKey: K.ollamaModel) ?? "llama3.1"
        let url = URL(string: "\(host)/api/generate")!
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // thinking モード（Qwen）用の system 前置き

        let qwenThinking = UserDefaults.standard.bool(forKey: K.qwenThinking)
        print("DEBUG: qwenThinking value is \(qwenThinking)") // この行を追加
        log("[Qwen] thinking=\(qwenThinking)")
        let prompt: String
        if qwenThinking {
            prompt = """
            <|system|>
            \(system)
            <|user|>
            \(text)
            <|assistant|>
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prompt = "\(system)\n\n---\n\n\(text)"
        }

        struct Body: Codable { let model: String; let prompt: String; let stream: Bool }
        let body = Body(model: model, prompt: prompt, stream: false)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data, vendor: "Ollama")

        struct Resp: Codable { let response: String? }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.response ?? ""
    }

    // MARK: - Helpers
    private func checkHTTP(_ resp: URLResponse, data: Data, vendor: String) throws {
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "(body decode failed)"
            throw err(vendor, http.statusCode, "HTTP \(http.statusCode)\n\(body)")
        }
    }

    private func err(_ domain: String, _ code: Int, _ msg: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: - キー取得（UserDefaults 優先、無ければ環境変数）
    private func readKey(names: [String]) -> (value: String?, source: String) {
        // UserDefaults 優先
        for defName in names {
            if let v = UserDefaults.standard.string(forKey: defName), !v.isEmpty {
                log("🔑 [Key] source=defaults:\(defName)")
                return (v, "defaults:\(defName)")
            }
        }
        // 環境変数
        for envName in names {
            if let v = ProcessInfo.processInfo.environment[envName], !v.isEmpty {
                log("🔑 [Key] source=env:\(envName)")
                return (v, "env:\(envName)")
            }
        }
        return (nil, "none (missing)")
    }
}

// MARK: - Logging
@inline(__always)
private func log(_ s: String) {
    print("[Summarizer] \(s)")
}
