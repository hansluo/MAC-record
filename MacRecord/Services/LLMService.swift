import Foundation

/// LLM API 调用服务（Swift 原生 URLSession，支持 OpenAI 兼容协议）
class LLMService {
    struct LLMResponse {
        let text: String
        let success: Bool
        let error: String?
    }

    /// 标准化 API URL — 确保以 /chat/completions 结尾
    /// 用户可能输入各种格式：
    ///   http://127.0.0.1:12314/v1          → http://127.0.0.1:12314/v1/chat/completions
    ///   http://127.0.0.1:12314/v1/         → http://127.0.0.1:12314/v1/chat/completions
    ///   http://127.0.0.1:12314             → http://127.0.0.1:12314/v1/chat/completions
    ///   https://api.deepseek.com/v1/chat/completions → 保持不变
    static func normalizeAPIURL(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移除末尾斜杠
        while u.hasSuffix("/") { u.removeLast() }

        // 已经是完整路径
        if u.hasSuffix("/chat/completions") { return u }

        // 以 /v1 结尾 → 补上 /chat/completions
        if u.hasSuffix("/v1") {
            return u + "/chat/completions"
        }

        // 以 /v1beta/openai 结尾（Gemini 格式）→ 补上 /chat/completions
        if u.hasSuffix("/openai") {
            return u + "/chat/completions"
        }

        // 只有 host:port，没有路径或路径不包含 /v → 补全 /v1/chat/completions
        if let parsed = URL(string: u) {
            let path = parsed.path
            if path.isEmpty || path == "/" || !path.contains("/v") {
                return u + "/v1/chat/completions"
            }
        }

        // 其他情况原样返回（用户自定义路径）
        return u
    }

    /// 同步调用 LLM API
    func call(
        text: String,
        prompt: String,
        apiURL: String,
        apiKey: String,
        modelName: String,
        maxTokens: Int = 8192,
        temperature: Double = 0.7
    ) async throws -> String {
        let normalizedURL = Self.normalizeAPIURL(apiURL)
        guard let url = URL(string: normalizedURL) else {
            throw LLMError.invalidURL
        }

        let fullPrompt: String
        if prompt.contains("{text}") {
            fullPrompt = prompt.replacingOccurrences(of: "{text}", with: text)
        } else {
            fullPrompt = "\(prompt)\n\n\(text)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 300

        let payload: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "user", "content": fullPrompt]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Self.classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 带 system message 的 LLM 调用（用于语音纠错、纪要生成等需要精确指令的场景）
    func callWithSystem(
        systemMessage: String,
        userMessage: String,
        apiURL: String,
        apiKey: String,
        modelName: String,
        maxTokens: Int = 2048,
        temperature: Double = 0.3
    ) async throws -> String {
        let normalizedURL = Self.normalizeAPIURL(apiURL)
        guard let url = URL(string: normalizedURL) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 300

        let payload: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Self.classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 测试连接
    func testConnection(apiURL: String, apiKey: String, modelName: String) async -> (success: Bool, message: String) {
        let normalizedURL = Self.normalizeAPIURL(apiURL)
        do {
            guard let url = URL(string: normalizedURL) else {
                return (false, "❌ 无效的 API 地址")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 15

            let payload: [String: Any] = [
                "model": modelName,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 10,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "❌ 无效响应")
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["choices"] != nil {
                    let urlNote = normalizedURL != apiURL ? " (已自动补全为 \(normalizedURL))" : ""
                    return (true, "✅ 连接成功: \(modelName)\(urlNote)")
                }
                return (false, "⚠️ 响应格式异常")
            }

            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return (false, "❌ 请求失败 (\(httpResponse.statusCode)): \(body)")
        } catch {
            return (false, "❌ 连接失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 本地模型检测

    /// 检测到的本地模型信息
    struct DetectedModel: Identifiable {
        let id = UUID().uuidString
        let name: String
        let provider: String   // "Ollama" / "LM Studio"
        let apiURL: String
        let size: String
    }

    /// 检测本地运行的 Ollama、LM Studio、oMLX 及自定义端口的模型
    func detectLocalModels(customPort: Int? = nil) async -> [DetectedModel] {
        async let ollamaModels = detectOllama()
        async let lmStudioModels = detectLMStudio()
        async let omlxModels = detectOMLX()

        var results: [DetectedModel] = []
        results.append(contentsOf: await ollamaModels)
        results.append(contentsOf: await lmStudioModels)
        results.append(contentsOf: await omlxModels)

        // 自定义端口检测（排除已检测的默认端口）
        let defaultPorts: Set<Int> = [11434, 1234, 8000]
        if let port = customPort, port > 0, !defaultPorts.contains(port) {
            let (customModels, _) = await detectByPort(port: port)
            results.append(contentsOf: customModels)
        }

        return results
    }

    /// 检测 oMLX（默认端口 8000）
    private func detectOMLX() async -> [DetectedModel] {
        let port = 8000
        let hosts = ["http://localhost:\(port)", "http://127.0.0.1:\(port)"]

        for baseURL in hosts {
            // oMLX 支持 OpenAI 兼容 /v1/models
            let models = await detectOpenAICompatAt(baseURL: baseURL, port: port, providerName: "oMLX")
            if !models.isEmpty { return models }
        }
        return []
    }

    /// 通用端口检测 — 多协议 + 多地址探测
    /// 返回 (检测到的模型, 诊断信息)
    func detectByPort(port: Int, apiKey: String = "") async -> (models: [DetectedModel], diagnostic: String) {
        // 同时尝试 localhost 和 127.0.0.1（服务可能绑定在其中一个）
        let hosts = ["http://localhost:\(port)", "http://127.0.0.1:\(port)"]
        var portReachable = false
        var needsAuth = false

        for baseURL in hosts {
            // 策略 1：尝试 Ollama /api/tags
            let ollamaModels = await detectOllamaAt(baseURL: baseURL, port: port)
            if !ollamaModels.isEmpty { return (ollamaModels, "") }

            // 策略 2：尝试 OpenAI 兼容 /v1/models（带 API Key）
            let openaiModels = await detectOpenAICompatAt(baseURL: baseURL, port: port, apiKey: apiKey)
            if !openaiModels.isEmpty { return (openaiModels, "") }

            // 检查是否因为需要认证而失败
            if await checkNeedsAuth(baseURL: baseURL) {
                needsAuth = true
                portReachable = true
            }
        }

        // 策略 3：根路径识别 + 检查端口是否可达
        for baseURL in hosts {
            let rootModels = await detectByRootProbe(baseURL: baseURL, port: port)
            if !rootModels.isEmpty { return (rootModels, "") }

            if await isPortReachable(baseURL: baseURL) {
                portReachable = true
            }
        }

        if needsAuth {
            return ([], "端口 \(port) 的服务需要 API Key 认证。请在下方填写 API Key 后重试")
        } else if portReachable {
            return ([], "端口 \(port) 有服务在运行，但未检测到可用模型。请确认：\n1. 模型已加载（oMLX 需在管理面板加载模型）\n2. 服务支持 OpenAI 兼容 /v1/models 接口")
        } else {
            return ([], "端口 \(port) 无服务响应。请确认服务已启动且端口正确。\noMLX 默认端口为 8000，Ollama 为 11434，LM Studio 为 1234")
        }
    }

    /// 检查 /v1/models 是否返回 401/403（需要认证）
    private func checkNeedsAuth(baseURL: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 401 || http.statusCode == 403
            }
            return false
        } catch {
            return false
        }
    }

    /// 检测端口是否可达（不关心返回什么，只看是否有响应）
    private func isPortReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    /// 探测 Ollama 原生接口 /api/tags
    private func detectOllamaAt(baseURL: String, port: Int) async -> [DetectedModel] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }

            return models.compactMap { m -> DetectedModel? in
                guard let name = m["name"] as? String else { return nil }
                let sizeBytes = m["size"] as? Int64 ?? 0
                let sizeStr = sizeBytes > 0 ? Self.formatBytes(sizeBytes) : ""
                return DetectedModel(
                    name: name,
                    provider: "Ollama (端口 \(port))",
                    apiURL: "\(baseURL)/v1/chat/completions",
                    size: sizeStr
                )
            }
        } catch {
            return []
        }
    }

    /// 探测 OpenAI 兼容接口 /v1/models
    private func detectOpenAICompatAt(baseURL: String, port: Int, providerName: String? = nil, apiKey: String = "") async -> [DetectedModel] {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }

            return models.compactMap { m -> DetectedModel? in
                guard let modelId = m["id"] as? String else { return nil }
                let provider = providerName ?? "本地服务 (端口 \(port))"
                return DetectedModel(
                    name: modelId,
                    provider: provider,
                    apiURL: "\(baseURL)/v1/chat/completions",
                    size: ""
                )
            }
        } catch {
            return []
        }
    }

    /// 根路径探测：检查服务是否在线，如果是 Ollama 会返回 "Ollama is running"
    private func detectByRootProbe(baseURL: String, port: Int) async -> [DetectedModel] {
        guard let url = URL(string: baseURL) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let body = String(data: data, encoding: .utf8) ?? ""

            if body.lowercased().contains("ollama") {
                // 是 Ollama 但 /api/tags 失败了，可能版本太旧，用 /v1/models 再试
                return await detectOpenAICompatAt(baseURL: baseURL, port: port)
            }
            // 其他服务在线但无法识别协议
            return []
        } catch {
            return []
        }
    }

    /// 检测 Ollama (默认端口 11434)
    private func detectOllama() async -> [DetectedModel] {
        let baseURL = "http://localhost:11434"
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }

            return models.compactMap { m -> DetectedModel? in
                guard let name = m["name"] as? String else { return nil }
                let sizeBytes = m["size"] as? Int64 ?? 0
                let sizeStr = sizeBytes > 0 ? Self.formatBytes(sizeBytes) : ""
                return DetectedModel(
                    name: name,
                    provider: "Ollama",
                    apiURL: "\(baseURL)/v1/chat/completions",
                    size: sizeStr
                )
            }
        } catch {
            return []
        }
    }

    /// 检测 LM Studio (默认端口 1234)
    private func detectLMStudio() async -> [DetectedModel] {
        let baseURL = "http://localhost:1234"
        guard let url = URL(string: "\(baseURL)/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }

            return models.compactMap { m -> DetectedModel? in
                guard let modelId = m["id"] as? String else { return nil }
                return DetectedModel(
                    name: modelId,
                    provider: "LM Studio",
                    apiURL: "\(baseURL)/v1/chat/completions",
                    size: ""
                )
            }
        } catch {
            return []
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - 错误分类

    /// 解析 LLM API 返回的 HTTP 错误，识别 context_length_exceeded 等特有错误
    static func classifyHTTPError(statusCode: Int, body: String) -> LLMError {
        let bodyLower = body.lowercased()

        // 检测 context length 超限（各家 API 的错误格式不同）
        if bodyLower.contains("context_length_exceeded")
            || bodyLower.contains("context length")
            || bodyLower.contains("maximum context")
            || bodyLower.contains("token limit")
            || bodyLower.contains("too many tokens")
            || bodyLower.contains("max_tokens")
            || (statusCode == 400 && bodyLower.contains("length")) {
            return .contextLengthExceeded(body)
        }

        // 检测速率限制
        if statusCode == 429 || bodyLower.contains("rate_limit") || bodyLower.contains("rate limit") {
            return .rateLimitExceeded(body)
        }

        return .httpError(statusCode, body)
    }
}

enum LLMError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case parseError
    case contextLengthExceeded(String)
    case rateLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 API 地址"
        case .invalidResponse: return "无效的响应"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parseError: return "响应解析失败"
        case .contextLengthExceeded: return "输入文本超出模型上下文长度限制"
        case .rateLimitExceeded: return "API 请求频率超限，请稍后重试"
        }
    }

    /// 是否为 context length 超限错误
    var isContextLengthExceeded: Bool {
        if case .contextLengthExceeded = self { return true }
        return false
    }
}
