import Foundation
import Combine

/// 模型下载管理器 — 负责下载、解压、验证模型文件
@MainActor
class ModelDownloadManager: ObservableObject {
    @Published var downloads: [ASRModelID: DownloadState] = [:]
    /// 已下载的模型 ID 集合（用于驱动 SwiftUI 刷新）
    @Published var downloadedModelIds: Set<ASRModelID> = []

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)  // 0.0 ~ 1.0
        case extracting
        case completed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .extracting: return true
            default: return false
            }
        }
    }

    private var downloadTasks: [ASRModelID: URLSessionDownloadTask] = [:]
    private var observations: [ASRModelID: NSKeyValueObservation] = [:]

    init() {
        refreshDownloadedModels()
    }

    /// 扫描文件系统，刷新已下载模型集合
    func refreshDownloadedModels() {
        var ids = Set<ASRModelID>()
        for modelId in ASRModelID.allCases {
            if ModelRegistry.isModelDownloaded(modelId) {
                ids.insert(modelId)
            }
        }
        downloadedModelIds = ids
    }

    /// 检查模型是否已下载（响应式）
    func isDownloaded(_ modelId: ASRModelID) -> Bool {
        downloadedModelIds.contains(modelId)
    }

    /// 开始下载模型
    func download(modelId: ASRModelID) {
        let info = ModelRegistry.model(for: modelId)
        guard let urlString = info.downloadURL, let url = URL(string: urlString) else {
            downloads[modelId] = .failed("无效的下载地址")
            return
        }
        guard !(downloads[modelId]?.isActive ?? false) else { return }

        downloads[modelId] = .downloading(progress: 0)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600  // 1 小时超时
        let session = URLSession(configuration: config)

        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.observations.removeValue(forKey: modelId)
                self.downloadTasks.removeValue(forKey: modelId)

                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.downloads[modelId] = .idle
                    } else {
                        self.downloads[modelId] = .failed("下载失败: \(error.localizedDescription)")
                    }
                    return
                }

                guard let tempURL = tempURL else {
                    self.downloads[modelId] = .failed("下载文件不存在")
                    return
                }

                self.downloads[modelId] = .extracting
                await self.extractAndInstall(modelId: modelId, archiveURL: tempURL, info: info)
            }
        }

        // 观察下载进度
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.downloads[modelId] = .downloading(progress: progress.fractionCompleted)
            }
        }
        observations[modelId] = observation
        downloadTasks[modelId] = task
        task.resume()
    }

    /// 取消下载
    func cancelDownload(modelId: ASRModelID) {
        downloadTasks[modelId]?.cancel()
        downloadTasks.removeValue(forKey: modelId)
        observations.removeValue(forKey: modelId)
        downloads[modelId] = .idle
    }

    /// 删除已下载的模型
    func deleteModel(modelId: ASRModelID) {
        let modelDir = ModelRegistry.modelDirectory(for: modelId)
        try? FileManager.default.removeItem(at: modelDir)
        downloads[modelId] = .idle
        refreshDownloadedModels()
    }

    // MARK: - 解压安装

    private func extractAndInstall(
        modelId: ASRModelID, archiveURL: URL, info: ASRModelInfo
    ) async {
        let modelDir = ModelRegistry.modelDirectory(for: modelId)
        let fm = FileManager.default

        do {
            // 确保模型目录存在
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // 复制临时文件到持久位置（避免系统清理）
            let localArchive = modelDir.appendingPathComponent("download.tar.bz2")
            if fm.fileExists(atPath: localArchive.path) {
                try fm.removeItem(at: localArchive)
            }
            try fm.copyItem(at: archiveURL, to: localArchive)

            // 解压 tar.bz2
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xjf", localArchive.path, "-C", modelDir.path, "--strip-components=1"]

            let errPipe = Pipe()
            process.standardError = errPipe

            try process.run()
            process.waitUntilExit()

            // 清理压缩包
            try? fm.removeItem(at: localArchive)

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "未知解压错误"
                throw ExtractError.extractFailed(errMsg)
            }

            // 验证关键文件
            guard ModelRegistry.isModelDownloaded(modelId) else {
                throw ExtractError.verifyFailed("模型文件不完整")
            }

            downloads[modelId] = .completed
            refreshDownloadedModels()

        } catch {
            // 清理失败的目录
            try? fm.removeItem(at: modelDir)
            downloads[modelId] = .failed("安装失败: \(error.localizedDescription)")
        }
    }

    enum ExtractError: LocalizedError {
        case extractFailed(String)
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .extractFailed(let msg): return "解压失败: \(msg)"
            case .verifyFailed(let msg): return "验证失败: \(msg)"
            }
        }
    }
}
