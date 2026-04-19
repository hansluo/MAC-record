import Foundation

/// ASR 桥接：管理 Python 子进程，通过 JSON-RPC over stdin/stdout 通信
actor ASRBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readBuffer = Data()
    private var isRunning = false

    // MARK: - 响应数据结构

    struct TranscribeResult {
        let plainText: String
        let timestampText: String
        let detectedLanguage: String?
        let duration: Double?
        let segments: [[String: Any]]
    }

    struct RealtimeSnapshot {
        let plainText: String
        let timestampText: String
        let llmPlainText: String
    }

    struct DiarizeResult {
        let labeledText: String
        let numSpeakers: Int
    }

    // MARK: - 生命周期

    func start() throws {
        guard !isRunning else { return }

        let pythonEnvDir = findPythonEnvDir()
        let pythonPath = pythonEnvDir + "/bin/python3"
        let serverScript = findASRServerScript()

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw ASRError.pythonNotFound(pythonPath)
        }
        guard FileManager.default.fileExists(atPath: serverScript) else {
            throw ASRError.serverScriptNotFound(serverScript)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [serverScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: pythonEnvDir)

        // 设置环境变量确保 Python 使用正确的 venv
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = pythonEnvDir
        env["PATH"] = "\(pythonEnvDir)/bin:" + (env["PATH"] ?? "")
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // 异步读取 stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.handleStdoutData(data)
            }
        }

        // stderr 日志输出
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("[ASR-stderr] \(text)", terminator: "")
            }
        }

        try proc.run()
        isRunning = true
        print("[ASRBridge] Python 子进程已启动 (PID: \(proc.processIdentifier))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }

        // 取消所有挂起的请求
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ASRError.bridgeStopped)
        }
        pendingRequests.removeAll()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        print("[ASRBridge] Python 子进程已停止")
    }

    // MARK: - RPC 方法

    func initModels() async throws -> String {
        let result = try await call(method: "init_models", params: [:])
        return result["status"] as? String ?? "模型加载完成"
    }

    func getModelStatus() async throws -> String {
        let result = try await call(method: "get_model_status", params: [:])
        return result["status"] as? String ?? "未知"
    }

    func transcribeFile(audioPath: String, language: String) async throws -> TranscribeResult {
        let result = try await call(method: "transcribe_file", params: [
            "audio_path": audioPath,
            "language": language,
        ])
        return TranscribeResult(
            plainText: result["plain_text"] as? String ?? "",
            timestampText: result["timestamp_text"] as? String ?? "",
            detectedLanguage: result["detected_lang"] as? String,
            duration: result["duration"] as? Double,
            segments: result["segments"] as? [[String: Any]] ?? []
        )
    }

    func realtimeStart(sessionId: String, language: String) async throws {
        _ = try await call(method: "realtime_start", params: [
            "session_id": sessionId,
            "language": language,
        ])
    }

    func realtimeFeed(sessionId: String, audioBase64: String) async throws -> String {
        let result = try await call(method: "realtime_feed", params: [
            "session_id": sessionId,
            "audio_base64": audioBase64,
        ])
        return result["text"] as? String ?? ""
    }

    func realtimeStop(sessionId: String) async throws -> TranscribeResult {
        let result = try await call(method: "realtime_stop", params: [
            "session_id": sessionId,
        ])
        return TranscribeResult(
            plainText: result["plain_text"] as? String ?? "",
            timestampText: result["timestamp_text"] as? String ?? "",
            detectedLanguage: result["detected_lang"] as? String,
            duration: result["duration"] as? Double,
            segments: []
        )
    }

    func getRealtimeSnapshot(sessionId: String) async throws -> RealtimeSnapshot {
        let result = try await call(method: "realtime_snapshot", params: [
            "session_id": sessionId,
        ])
        return RealtimeSnapshot(
            plainText: result["plain_text"] as? String ?? "",
            timestampText: result["timestamp_text"] as? String ?? "",
            llmPlainText: result["llm_plain_text"] as? String ?? ""
        )
    }

    func diarize(audioPath: String) async throws -> DiarizeResult {
        let result = try await call(method: "diarize", params: [
            "audio_path": audioPath,
        ])
        return DiarizeResult(
            labeledText: result["labeled_text"] as? String ?? "",
            numSpeakers: result["num_speakers"] as? Int ?? 0
        )
    }

    // MARK: - JSON-RPC 通信

    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isRunning else { throw ASRError.bridgeNotRunning }

        let requestId = nextRequestId
        nextRequestId += 1

        let request: [String: Any] = [
            "id": requestId,
            "method": method,
            "params": params,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ASRError.serializationFailed
        }
        jsonString += "\n"

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[requestId] = continuation

            guard let data = jsonString.data(using: .utf8),
                  let stdin = self.stdinPipe else {
                self.pendingRequests.removeValue(forKey: requestId)
                continuation.resume(throwing: ASRError.bridgeNotRunning)
                return
            }

            stdin.fileHandleForWriting.write(data)
        }
    }

    private func handleStdoutData(_ data: Data) {
        readBuffer.append(data)

        // 按换行符分割，每行一个 JSON 响应
        while let newlineRange = readBuffer.range(of: Data("\n".utf8)) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineRange.lowerBound]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineRange.lowerBound)

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let requestId = json["id"] as? Int else { continue }

            if let continuation = pendingRequests.removeValue(forKey: requestId) {
                if let error = json["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "未知错误"
                    continuation.resume(throwing: ASRError.rpcError(message))
                } else if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: [:])
                }
            }
        }
    }

    // MARK: - 路径发现

    private func findPythonEnvDir() -> String {
        // 优先使用 app bundle 内的 python_env
        if let bundlePath = Bundle.main.resourcePath {
            let bundleEnv = bundlePath + "/python_env"
            if FileManager.default.fileExists(atPath: bundleEnv + "/bin/python3") {
                return bundleEnv
            }
        }

        // 回退到开发环境路径
        let devPath = NSHomeDirectory() + "/Desktop/whisper_env"
        if FileManager.default.fileExists(atPath: devPath + "/bin/python3") {
            return devPath
        }

        return "/usr/local/bin"
    }

    private func findASRServerScript() -> String {
        // 优先使用 app bundle 内的
        if let bundlePath = Bundle.main.resourcePath {
            let bundleScript = bundlePath + "/python_env/asr_server.py"
            if FileManager.default.fileExists(atPath: bundleScript) {
                return bundleScript
            }
        }

        // 回退到开发环境
        let devPath = NSHomeDirectory() + "/Desktop/whisper_env/asr_server.py"
        return devPath
    }
}

// MARK: - Errors

enum ASRError: LocalizedError {
    case pythonNotFound(String)
    case serverScriptNotFound(String)
    case bridgeNotRunning
    case bridgeStopped
    case serializationFailed
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound(let path): return "Python 不存在: \(path)"
        case .serverScriptNotFound(let path): return "ASR 服务脚本不存在: \(path)"
        case .bridgeNotRunning: return "ASR 引擎未运行"
        case .bridgeStopped: return "ASR 引擎已停止"
        case .serializationFailed: return "JSON 序列化失败"
        case .rpcError(let msg): return "ASR 错误: \(msg)"
        }
    }
}
