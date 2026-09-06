import Foundation

actor MOSSSidecarRunner: FileASRBackend {
    let modelId: ASRModelID = .mossTranscribeDiarize09B
    let capabilities: ASRCapabilities = .moss

    private var activeProcess: Process?
    private var activeRequestId: String?

    func healthCheck() async throws {
        let response = try await execute(command: "health", audioURL: nil, hotwords: [], timeout: 30)
        guard response.type == "health", response.ready == true else {
            throw MOSSRuntimeError.protocolError(response.message ?? "运行环境未就绪")
        }
    }

    func transcribeFile(
        at url: URL,
        hotwords: [String] = []
    ) async throws -> UnifiedTranscriptionResult {
        let response = try await execute(
            command: "transcribe",
            audioURL: url,
            hotwords: hotwords,
            timeout: 7_200
        )
        guard response.type == "result", let text = response.text else {
            if response.type == "cancelled" { throw MOSSRuntimeError.cancelled }
            throw MOSSRuntimeError.protocolError(response.message ?? "未收到转录结果")
        }
        let segments = (response.segments ?? []).map {
            TranscriptionSegment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text)
        }
        let diagnostics: String?
        if let tokens = response.generationTokens, let tps = response.generationTPS {
            diagnostics = "生成 \(tokens) tokens，\(String(format: "%.1f", tps)) tokens/s"
        } else {
            diagnostics = nil
        }
        return UnifiedTranscriptionResult(
            text: text,
            language: response.language,
            segments: segments,
            engineId: modelId.rawValue,
            modelVersion: response.modelId,
            duration: segments.map(\.end).max(),
            elapsed: response.elapsed,
            diagnostics: diagnostics
        )
    }

    func cancel() async {
        if let activeProcess { ProcessRunner.terminate(activeProcess) }
    }

    private func execute(
        command: String,
        audioURL: URL?,
        hotwords: [String],
        timeout: TimeInterval
    ) async throws -> SidecarResponse {
        guard MOSSRuntimeEnvironment.isInstalled else {
            throw MOSSRuntimeError.runtimeNotInstalled
        }
        guard let scriptURL = MOSSRuntimeEnvironment.sidecarScriptURL else {
            throw MOSSRuntimeError.sidecarMissing
        }
        guard activeProcess == nil else {
            throw MOSSRuntimeError.protocolError("已有 MOSS 任务正在运行")
        }

        let requestId = UUID().uuidString
        let request = SidecarRequest(
            protocolVersion: 1,
            requestId: requestId,
            command: command,
            audioPath: audioURL?.path,
            modelId: MOSSRuntimeEnvironment.modelId,
            hotwords: hotwords,
            maxTokens: 8_192
        )
        let requestData = try JSONEncoder().encode(request)

        let process = Process()
        process.executableURL = MOSSRuntimeEnvironment.pythonURL
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HOME"] = MOSSRuntimeEnvironment.modelCacheURL.path
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        activeProcess = process
        activeRequestId = requestId
        defer {
            if process.isRunning { ProcessRunner.terminate(process) }
            if activeRequestId == requestId {
                activeProcess = nil
                activeRequestId = nil
            }
        }
        try process.run()

        inputPipe.fileHandleForWriting.write(requestData)
        inputPipe.fileHandleForWriting.write(Data([0x0A]))
        try? inputPipe.fileHandleForWriting.close()

        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timedOut = SidecarTimeoutFlag()
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            ProcessRunner.terminate(process)
        }
        let status = await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        timeoutTask.cancel()
        let output = await outputTask.value
        let errorOutput = await errorTask.value
        if timedOut.value { throw MOSSRuntimeError.timedOut }
        if Task.isCancelled { throw MOSSRuntimeError.cancelled }

        let responses = output.split(separator: 0x0A).compactMap { line in
            try? JSONDecoder().decode(SidecarResponse.self, from: Data(line))
        }.filter { $0.requestId == nil || $0.requestId == requestId }

        if let error = responses.last(where: { $0.type == "error" }) {
            throw MOSSRuntimeError.protocolError(error.message ?? error.code ?? "未知错误")
        }
        if let final = responses.last(where: { ["result", "health", "cancelled"].contains($0.type) }) {
            return final
        }

        let stderr = String(data: errorOutput.suffix(8_192), encoding: .utf8) ?? ""
        if status != 0 {
            throw MOSSRuntimeError.protocolError(stderr.isEmpty ? "sidecar 退出码 \(status)" : stderr)
        }
        throw MOSSRuntimeError.protocolError("sidecar 未返回有效 JSONL")
    }
}

private final class SidecarTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

private struct SidecarRequest: Encodable {
    let protocolVersion: Int
    let requestId: String
    let command: String
    let audioPath: String?
    let modelId: String
    let hotwords: [String]
    let maxTokens: Int
}

private struct SidecarResponse: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let speaker: String?
        let text: String
    }

    let protocolVersion: Int
    let type: String
    let requestId: String?
    let ready: Bool?
    let code: String?
    let message: String?
    let diagnostics: String?
    let text: String?
    let language: String?
    let segments: [Segment]?
    let modelId: String?
    let elapsed: Double?
    let promptTokens: Int?
    let generationTokens: Int?
    let generationTPS: Double?
}
