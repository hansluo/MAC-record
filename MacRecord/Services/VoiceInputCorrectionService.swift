import Foundation

/// 语音输入 LLM 纠错服务 — 分层策略
/// ≤10 字直出，10~50 字纠错+加标点，50+ 字纠错+整理
class VoiceInputCorrectionService {

    /// 纠错结果
    struct CorrectionResult {
        let originalText: String
        let correctedText: String
        let didUseLLM: Bool
    }

    // MARK: - 配置

    /// 短句阈值（≤此值直接输出，不过 LLM）
    var shortThreshold: Int = 10

    /// LLM 超时时间（秒）
    var llmTimeoutSeconds: TimeInterval = 10

    // MARK: - 纠错

    /// 对 ASR 文本进行 LLM 纠错
    /// - Parameters:
    ///   - text: ASR 原始识别文本
    ///   - model: 纠错使用的 LLM 模型（由调用方解析好）
    ///   - customPrompt: 自定义纠错 prompt（非空时替代内置 prompt）
    /// - Returns: 纠错后的结果
    func correct(text: String, model: LLMModelConfig?, customPrompt: String? = nil) async -> CorrectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CorrectionResult(originalText: text, correctedText: "", didUseLLM: false)
        }

        let charCount = trimmed.count

        // 无 LLM 模型时直出原文
        guard let model = model else {
            print("[VoiceCorrection] 无 LLM 模型，直出原文")
            return CorrectionResult(originalText: text, correctedText: trimmed, didUseLLM: false)
        }

        let systemPrompt: String
        if let custom = customPrompt, !custom.isEmpty {
            systemPrompt = custom
        } else {
            systemPrompt = buildSystemPrompt(charCount: charCount)
        }
        let llmService = LLMService()

        do {
            let corrected = try await withTimeout(seconds: llmTimeoutSeconds) {
                try await llmService.callWithSystem(
                    systemMessage: systemPrompt,
                    userMessage: trimmed,
                    apiURL: model.apiURL,
                    apiKey: model.apiKey,
                    modelName: model.modelName,
                    maxTokens: 2048,
                    temperature: 0.3
                )
            }

            let result = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            // 防御：如果 LLM 返回空文本或明显异常，fallback 到原文
            if result.isEmpty || result.count > trimmed.count * 3 {
                print("[VoiceCorrection] LLM 返回异常，fallback 到原文")
                return CorrectionResult(originalText: text, correctedText: trimmed, didUseLLM: false)
            }

            return CorrectionResult(originalText: text, correctedText: result, didUseLLM: true)
        } catch {
            print("[VoiceCorrection] LLM 纠错失败: \(error.localizedDescription)，fallback 到原文")
            return CorrectionResult(originalText: text, correctedText: trimmed, didUseLLM: false)
        }
    }

    // MARK: - Prompt 构建

    private func buildSystemPrompt(charCount: Int) -> String {
        if charCount <= 15 {
            // 短句：重点纠正同音字，保持简洁
            return """
            你是语音输入纠错助手。用户通过语音输入了一段简短文字，ASR 引擎可能产生严重的同音字/近音字错误。
            例如："扁奏穴位题" 实际应为 "眼周穴位贴"，"公寓" 实际应为 "公司"。
            请根据语义推断正确文字。
            规则：
            1. 重点纠正同音字/近音字/形近字错误，从语义角度推断用户实际想说的内容
            2. 如有需要添加标点符号
            3. 不要改变原意，不要扩写
            4. 直接输出修正后的文字，不要有任何解释
            """
        } else if charCount <= 50 {
            return """
            你是语音输入纠错助手。用户通过语音输入了一段文字，可能有同音字错误、缺少标点。
            请修正为正确的书面文字。
            规则：
            1. 纠正同音字/近音字/形近字错误，从语义角度推断正确内容
            2. 添加正确的标点符号
            3. 不要改变原意
            4. 不要扩写或添加用户没说的内容
            5. 直接输出修正后的文字，不要有任何解释
            """
        } else {
            return """
            你是语音输入纠错助手。用户通过语音输入了一段较长的文字，可能有同音字错误、缺少标点、含有口头禅。
            请修正为流畅的书面文字。
            规则：
            1. 纠正同音字/近音字/形近字错误
            2. 添加正确的标点符号
            3. 删除明显的口头禅（如"那个"、"就是"、"嗯"等重复出现时）
            4. 保持原意不变，不要扩写或添加内容
            5. 直接输出修正后的文字，不要有任何解释
            """
        }
    }

    // MARK: - 超时工具

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CorrectionError.timeout
            }

            guard let result = try await group.next() else {
                throw CorrectionError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

enum CorrectionError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout: return "LLM 纠错超时"
        }
    }
}
