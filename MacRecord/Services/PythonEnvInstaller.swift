import Foundation

/// Python 环境自动安装器
/// 负责：1) 检测系统 Python3  2) 创建 venv  3) 安装 FunASR 依赖  4) 部署 asr_server.py
@MainActor
class PythonEnvInstaller: ObservableObject {
    @Published var state: InstallState = .idle
    @Published var progress: String = ""
    @Published var detailLog: String = ""

    enum InstallState: Equatable {
        case idle
        case checking
        case installing
        case completed
        case failed(String)
    }

    private let envPath: String
    private var installTask: Task<Void, Never>?

    init() {
        self.envPath = ASRConfigStore.pythonEnvPath
    }

    /// 检查 Python 环境是否已就绪
    var isReady: Bool {
        let pythonPath = envPath + "/bin/python3"
        let serverScript = envPath + "/asr_server.py"
        return FileManager.default.fileExists(atPath: pythonPath)
            && FileManager.default.fileExists(atPath: serverScript)
    }

    /// 检查系统是否有 Python3
    var systemPythonPath: String? {
        ASRConfigStore.findSystemPython()
    }

    /// 开始安装流程
    func startInstall() {
        guard state != .installing else { return }
        installTask = Task {
            await install()
        }
    }

    /// 取消安装
    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        state = .idle
        progress = ""
    }

    // MARK: - 安装流程

    private func install() async {
        state = .installing
        detailLog = ""

        do {
            // Step 1: 检查系统 Python
            progress = "检查系统 Python3…"
            appendLog("🔍 检查系统 Python3")

            guard let sysPython = systemPythonPath else {
                throw InstallError.noPython
            }
            appendLog("✅ 找到 Python3: \(sysPython)")

            // 验证 Python 版本
            let version = try await runCommand(sysPython, args: ["--version"])
            appendLog("   版本: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")

            // Step 2: 创建虚拟环境
            progress = "创建 Python 虚拟环境…"
            appendLog("📦 创建虚拟环境: \(envPath)")

            // 确保父目录存在
            let parentDir = (envPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir, withIntermediateDirectories: true
            )

            // 如果已存在旧的不完整环境，先删除
            if FileManager.default.fileExists(atPath: envPath) {
                let pythonExists = FileManager.default.fileExists(atPath: envPath + "/bin/python3")
                if !pythonExists {
                    try FileManager.default.removeItem(atPath: envPath)
                    appendLog("   删除了不完整的旧环境")
                }
            }

            if !FileManager.default.fileExists(atPath: envPath + "/bin/python3") {
                _ = try await runCommand(sysPython, args: ["-m", "venv", envPath])
                appendLog("✅ 虚拟环境创建完成")
            } else {
                appendLog("✅ 虚拟环境已存在")
            }

            // Step 3: 安装依赖
            let pip = envPath + "/bin/pip3"
            let python = envPath + "/bin/python3"

            progress = "升级 pip…"
            appendLog("⬆️  升级 pip")
            _ = try await runCommand(python, args: ["-m", "pip", "install", "--upgrade", "pip"],
                                     timeout: 120)

            progress = "安装 FunASR 和依赖（可能需要几分钟）…"
            appendLog("📥 安装 funasr, torch, modelscope…")
            appendLog("   这可能需要 5-10 分钟，取决于网络速度")

            _ = try await runCommand(pip, args: [
                "install", "--no-cache-dir",
                "funasr", "torch", "torchaudio", "modelscope", "onnxruntime"
            ], timeout: 600)
            appendLog("✅ Python 依赖安装完成")

            // Step 4: 部署 asr_server.py
            progress = "部署 ASR 服务脚本…"
            appendLog("📄 部署 asr_server.py")
            try deployASRServer()
            appendLog("✅ asr_server.py 已部署")

            // Step 5: 验证
            progress = "验证安装…"
            appendLog("🔍 验证安装")
            let verifyResult = try await runCommand(
                python, args: ["-c", "import funasr; print('FunASR version:', funasr.__version__)"],
                timeout: 30
            )
            appendLog("✅ \(verifyResult.trimmingCharacters(in: .whitespacesAndNewlines))")

            state = .completed
            progress = "安装完成"
            appendLog("\n🎉 Python 环境安装完成！可以切换到 SenseVoice (Python) 引擎了。")

        } catch is CancellationError {
            state = .idle
            progress = "安装已取消"
        } catch let error as InstallError {
            state = .failed(error.localizedDescription)
            progress = "安装失败"
            appendLog("❌ \(error.localizedDescription)")
        } catch {
            state = .failed(error.localizedDescription)
            progress = "安装失败"
            appendLog("❌ \(error.localizedDescription)")
        }
    }

    // MARK: - 部署 asr_server.py

    private func deployASRServer() throws {
        // 从 App Bundle 复制
        if let bundlePath = Bundle.main.resourcePath {
            let bundleScript = bundlePath + "/python_env/asr_server.py"
            if FileManager.default.fileExists(atPath: bundleScript) {
                let dest = envPath + "/asr_server.py"
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: bundleScript, toPath: dest)
                return
            }
        }

        // 从开发环境复制
        let devScript = NSHomeDirectory() + "/Desktop/whisper_env/asr_server.py"
        if FileManager.default.fileExists(atPath: devScript) {
            let dest = envPath + "/asr_server.py"
            if FileManager.default.fileExists(atPath: dest) {
                try FileManager.default.removeItem(atPath: dest)
            }
            try FileManager.default.copyItem(atPath: devScript, toPath: dest)
            return
        }

        throw InstallError.scriptNotFound
    }

    // MARK: - 命令执行

    private func runCommand(_ executable: String, args: [String], timeout: TimeInterval = 60) async throws -> String {
        try Task.checkCancellation()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        try proc.run()

        // 超时控制
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            if proc.isRunning { proc.terminate() }
        }

        proc.waitUntilExit()
        timeoutTask.cancel()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            let lastLines = errOutput.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
            throw InstallError.commandFailed(executable + " " + args.joined(separator: " "), lastLines)
        }

        return output
    }

    private func appendLog(_ text: String) {
        detailLog += text + "\n"
    }

    // MARK: - Errors

    enum InstallError: LocalizedError {
        case noPython
        case commandFailed(String, String)
        case scriptNotFound

        var errorDescription: String? {
            switch self {
            case .noPython:
                return "未检测到系统 Python3。请先安装 Python3：\n• Homebrew: brew install python3\n• 官网: python.org/downloads"
            case .commandFailed(let cmd, let err):
                return "命令执行失败: \(cmd)\n\(err)"
            case .scriptNotFound:
                return "未找到 asr_server.py 脚本"
            }
        }
    }
}
