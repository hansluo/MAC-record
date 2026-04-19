import Foundation

/// 长文本分段纪要生成器
class SummaryGenerator {
    private let llmService = LLMService()
    private let configStore: LLMConfigStore

    /// 默认分段阈值（字符数）— 当模型未设置 contextWindow 时使用
    private let defaultChunkThreshold = 32000
    private let maxTokens = 8192

    /// 进度回调：(当前段, 总段数, 阶段描述)
    var onProgress: ((Int, Int, String) -> Void)?

    init(configStore: LLMConfigStore) {
        self.configStore = configStore
    }

    /// 根据模型 contextWindow 计算分段阈值（字符数）
    /// 中文约 1.5-2 token/字，prompt 预留 2000 token，输出预留 maxTokens
    private func computeChunkThreshold(config: LLMModelConfig) -> Int {
        guard config.contextWindow > 0 else { return defaultChunkThreshold }
        let availableInputTokens = config.contextWindow - maxTokens - 2000
        guard availableInputTokens > 1000 else { return 4000 }
        let maxChars = Int(Double(availableInputTokens) / 1.5)
        return min(maxChars, defaultChunkThreshold)
    }

    /// 生成 AI 纪要（自动处理长文本分段）
    func generateSummary(text: String, customPrompt: String? = nil) async throws -> String {
        guard let config = configStore.activeModel else {
            throw SummaryError.noModelConfigured
        }

        let apiKey = config.apiKey
        let prompt = customPrompt ?? configStore.activePrompt
        let chunkThreshold = computeChunkThreshold(config: config)

        print("[SummaryGenerator] 文本长度: \(text.count)字, 分段阈值: \(chunkThreshold)字, contextWindow: \(config.contextWindow)")

        if text.count <= chunkThreshold {
            onProgress?(1, 1, "正在生成纪要…")
            return try await callWithRetry(
                text: text, prompt: prompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold
            )
        }

        // 长文本分段处理
        let chunks = splitByParagraphs(text: text, maxChars: chunkThreshold)

        if chunks.count == 1 {
            onProgress?(1, 1, "正在生成纪要…")
            return try await callWithRetry(
                text: chunks[0], prompt: prompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold
            )
        }

        // 逐段处理
        let totalChunks = chunks.count
        print("[SummaryGenerator] 分为 \(totalChunks) 段处理")
        var segmentSummaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            onProgress?(index + 1, totalChunks, "正在处理第 \(index + 1)/\(totalChunks) 段…")

            let segmentPrefix = "【以下是完整录音的第 \(index + 1)/\(totalChunks) 部分】\n\n"
            let segmentPrompt: String
            if prompt.contains("{text}") {
                segmentPrompt = prompt.replacingOccurrences(of: "{text}", with: segmentPrefix + "{text}")
            } else {
                segmentPrompt = prompt + "\n\n" + segmentPrefix + "{text}"
            }

            let result = try await callWithRetry(
                text: chunk, prompt: segmentPrompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold
            )
            segmentSummaries.append("【第 \(index + 1) 部分】\n\(result)")
            print("[SummaryGenerator] 段 \(index + 1)/\(totalChunks) 完成")
        }

        let merged = segmentSummaries.joined(separator: "\n\n")

        // ★ 所有多段结果都做全局整合（递归支持）
        onProgress?(totalChunks, totalChunks, "正在整合全部纪要…")
        return try await mergeSegments(
            merged: merged, userPrompt: prompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold, depth: 0
        )
    }

    // MARK: - 递归整合

    /// 递归整合分段纪要（最多 2 层递归，防止无限循环）
    private func mergeSegments(
        merged: String, userPrompt: String, config: LLMModelConfig, apiKey: String, chunkThreshold: Int, depth: Int
    ) async throws -> String {
        let mergePrompt = """
        以下是一段长录音分段处理后的多份纪要，请将它们整合为一份完整、连贯的纪要。
        整合要求：
        1. 完整保留所有段落中的讨论内容、观点、数据和细节，不要精简或压缩
        2. 仅合并明显重复的内容（同一件事在不同段出现），不同话题的内容全部保留
        3. 按讨论议题/时间线重新组织结构
        4. 输出风格和格式与各分段纪要保持一致

        {text}
        """

        // 如果整合文本本身不超限，直接调用
        if merged.count <= chunkThreshold {
            do {
                return try await callWithRetry(
                    text: merged, prompt: mergePrompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold
                )
            } catch {
                print("[SummaryGenerator] 全局整合失败(depth=\(depth))，返回拼接版: \(error.localizedDescription)")
                return merged
            }
        }

        // 整合文本超长且未到递归上限 → 分段后逐段整合再合并
        guard depth < 2 else {
            print("[SummaryGenerator] 递归整合到达上限(depth=\(depth))，返回拼接版")
            return merged
        }

        print("[SummaryGenerator] 整合文本超长(\(merged.count)字)，递归分段整合(depth=\(depth))")
        let subChunks = splitByParagraphs(text: merged, maxChars: chunkThreshold)
        var subResults: [String] = []
        for sub in subChunks {
            do {
                let result = try await callWithRetry(
                    text: sub, prompt: mergePrompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold
                )
                subResults.append(result)
            } catch {
                subResults.append(sub)
            }
        }
        let reMerged = subResults.joined(separator: "\n\n")
        return try await mergeSegments(
            merged: reMerged, userPrompt: userPrompt, config: config, apiKey: apiKey, chunkThreshold: chunkThreshold, depth: depth + 1
        )
    }

    // MARK: - LLM 调用（带自动重试）

    /// 调用 LLM，如果遇到 context_length_exceeded 自动将文本切半重试
    private func callWithRetry(
        text: String, prompt: String, config: LLMModelConfig, apiKey: String, chunkThreshold: Int
    ) async throws -> String {
        do {
            return try await llmService.call(
                text: text, prompt: prompt,
                apiURL: config.apiURL, apiKey: apiKey,
                modelName: config.modelName, maxTokens: maxTokens
            )
        } catch let error as LLMError where error.isContextLengthExceeded {
            // ★ context 超限：将文本切半，分别调用后合并
            print("[SummaryGenerator] context 超限，切半重试 (\(text.count)字)")
            let halfSize = max(text.count / 2, 1000)
            let subChunks = splitByParagraphs(text: text, maxChars: halfSize)
            var subResults: [String] = []
            for sub in subChunks {
                // 递归重试（如果再超限会继续切半，最多递归 3 层 = 1/8 原文）
                let subResult = try await llmService.call(
                    text: sub, prompt: prompt,
                    apiURL: config.apiURL, apiKey: apiKey,
                    modelName: config.modelName, maxTokens: maxTokens
                )
                subResults.append(subResult)
            }
            return subResults.joined(separator: "\n\n")
        }
    }

    /// 智能分割文本 — 优先按段落分，段落不足时按句子分，最后按固定长度分
    private func splitByParagraphs(text: String, maxChars: Int) -> [String] {
        // 第一层：按 \n\n 分段
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // 如果有多个段落且最长段落不超过阈值，按段落合并
        if paragraphs.count > 1 {
            var chunks: [String] = []
            var current = ""
            for para in paragraphs {
                let test = current.isEmpty ? para : current + "\n\n" + para
                if test.count > maxChars {
                    if !current.isEmpty { chunks.append(current) }
                    // 单段超长，递归用句子分割
                    if para.count > maxChars {
                        chunks.append(contentsOf: splitBySentences(text: para, maxChars: maxChars))
                        current = ""
                    } else {
                        current = para
                    }
                } else {
                    current = test
                }
            }
            if !current.isEmpty { chunks.append(current) }
            if chunks.count > 1 { return chunks }
        }

        // 第二层：没有 \n\n 分段（ASR 连续文本），按句子分
        let sentenceChunks = splitBySentences(text: text, maxChars: maxChars)
        if sentenceChunks.count > 1 { return sentenceChunks }

        // 第三层：连句子标点都没有，按固定字符数硬切
        return splitByFixedLength(text: text, maxChars: maxChars)
    }

    /// 按中英文句子标点分割
    private func splitBySentences(text: String, maxChars: Int) -> [String] {
        // 中文句号、问号、叹号、分号 + 英文句号后跟空格
        let sentenceEnders: [Character] = ["。", "？", "！", "；", ".", "?", "!"]

        var chunks: [String] = []
        var current = ""
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            current.append(ch)

            // 检查是否到了句子结尾
            let isSentenceEnd = sentenceEnders.contains(ch)

            if isSentenceEnd && current.count >= maxChars / 2 {
                // 已经积累了足够长度，在句子结尾处切分
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else if current.count >= maxChars {
                // 超长但没遇到句子结尾，找最近的标点切
                if let lastPuncIdx = current.lastIndex(where: { sentenceEnders.contains($0) }),
                   current.distance(from: current.startIndex, to: lastPuncIdx) > maxChars / 4 {
                    let cutPoint = current.index(after: lastPuncIdx)
                    let chunk = String(current[current.startIndex..<cutPoint])
                    let remainder = String(current[cutPoint...])
                    chunks.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = remainder
                } else {
                    // 完全没标点，硬切
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }

            i = text.index(after: i)
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 尾部不足一段，合并到最后一个 chunk
            if let last = chunks.last, last.count + current.count <= maxChars {
                chunks[chunks.count - 1] = last + current
            } else {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return chunks.isEmpty ? [text] : chunks
    }

    /// 按固定长度硬分割（最后手段）
    private func splitByFixedLength(text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks.isEmpty ? [text] : chunks
    }
}

enum SummaryError: LocalizedError {
    case noModelConfigured
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured: return "未配置 AI 模型"
        case .generationFailed(let msg): return "纪要生成失败: \(msg)"
        }
    }
}
