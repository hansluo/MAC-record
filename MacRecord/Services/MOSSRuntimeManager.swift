import Foundation

struct MOSSRuntimeEnvironment {
    static let repositoryRevision = "d2546316f76e93947e8d99a17fb88652f8ad6ab2"
    static let modelId = "vanch007/mlx-MOSS-Transcribe-Diarize-8bit"

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRecord/moss-runtime", isDirectory: true)
    }

    static var virtualEnvironment: URL {
        rootDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    static var pythonURL: URL {
        virtualEnvironment.appendingPathComponent("bin/python3")
    }

    static var markerURL: URL {
        rootDirectory.appendingPathComponent("installed.json")
    }

    static var modelCacheURL: URL {
        rootDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return false
        }
        return marker["revision"] == repositoryRevision
            && marker["model"] == modelId
            && FileManager.default.fileExists(atPath: modelCacheURL.path)
    }

    static var sidecarScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "moss_sidecar", withExtension: "py") {
            return bundled
        }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/moss/moss_sidecar.py")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }
}

@MainActor
final class MOSSRuntimeManager: ObservableObject {
    enum State: Equatable {
        case idle
        case installing(String)
        case ready
        case failed(String)

        var isActive: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = MOSSRuntimeEnvironment.isInstalled ? .ready : .idle
    private var activeProcess: Process?

    func install() async {
        guard !state.isActive else { return }
        state = .installing("正在检查 Python…")
        do {
            let python = try await Self.findCompatiblePython()
            try FileManager.default.createDirectory(
                at: MOSSRuntimeEnvironment.rootDirectory,
                withIntermediateDirectories: true
            )
            state = .installing("正在创建独立运行环境…")
            try await runCommand(python, arguments: [
                "-m", "venv", MOSSRuntimeEnvironment.virtualEnvironment.path,
            ])
            try Task.checkCancellation()
            state = .installing("正在安装 MLX 运行时…")
            let package = "moss-transcribe-diarize[mlx-runtime] @ git+https://github.com/vanch007/mlx-MOSS-Transcribe-Diarize.git@\(MOSSRuntimeEnvironment.repositoryRevision)"
            try await runCommand(MOSSRuntimeEnvironment.pythonURL, arguments: [
                "-m", "pip", "install", "--disable-pip-version-check", "--no-input", package,
            ])
            try Task.checkCancellation()
            state = .installing("正在下载并验证 MOSS-TD 8-bit 模型…")
            let prepareScript = "from moss_transcribe_diarize.mlx import load_model; load_model('" + MOSSRuntimeEnvironment.modelId + "', strict=True); print('ready')"
            var modelEnvironment = ProcessInfo.processInfo.environment
            modelEnvironment["HF_HOME"] = MOSSRuntimeEnvironment.modelCacheURL.path
            try await runCommand(
                MOSSRuntimeEnvironment.pythonURL,
                arguments: ["-c", prepareScript],
                environment: modelEnvironment,
                timeout: 7_200
            )
            let marker: [String: String] = [
                "revision": MOSSRuntimeEnvironment.repositoryRevision,
                "model": MOSSRuntimeEnvironment.modelId,
                "installedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: MOSSRuntimeEnvironment.markerURL, options: .atomic)
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancelInstallation() {
        if let activeProcess { ProcessRunner.terminate(activeProcess) }
        activeProcess = nil
        state = .idle
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: MOSSRuntimeEnvironment.rootDirectory.path) {
            try FileManager.default.removeItem(at: MOSSRuntimeEnvironment.rootDirectory)
        }
        state = .idle
    }

    func refresh() {
        state = MOSSRuntimeEnvironment.isInstalled ? .ready : .idle
    }

    private func runCommand(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 1_800
    ) async throws {
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            onStart: { [weak self] process in
                Task { @MainActor in self?.activeProcess = process }
            }
        )
        activeProcess = nil
        try Task.checkCancellation()
        guard result.status == 0 else {
            let message = String(data: result.standardError, encoding: .utf8) ?? "退出码 \(result.status)"
            throw MOSSRuntimeError.installFailed(message)
        }
    }

    private static func findCompatiblePython() async throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if (try? await run(url, arguments: [
                "-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)",
            ])) != nil {
                return url
            }
        }
        throw MOSSRuntimeError.pythonUnavailable
    }

    private static func run(_ executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        guard status == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data.suffix(8_192), encoding: .utf8) ?? "退出码 \(status)"
            throw MOSSRuntimeError.installFailed(message)
        }
    }
}

enum MOSSRuntimeError: LocalizedError {
    case pythonUnavailable
    case installFailed(String)
    case sidecarMissing
    case runtimeNotInstalled
    case protocolError(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            return "未找到 Python 3.10 或更高版本，请先安装 Python 3"
        case .installFailed(let message):
            return "MOSS 运行环境安装失败：\(message)"
        case .sidecarMissing:
            return "MOSS sidecar 脚本缺失"
        case .runtimeNotInstalled:
            return "请先在设置中安装 MOSS MLX 运行环境"
        case .protocolError(let message):
            return "MOSS 通信失败：\(message)"
        case .timedOut:
            return "MOSS 转录超时"
        case .cancelled:
            return "MOSS 转录已取消"
        }
    }
}
