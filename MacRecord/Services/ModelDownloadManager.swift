import Foundation
import Combine
import CryptoKit

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
        case installing(String)
        case completed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .extracting, .installing: return true
            default: return false
            }
        }
    }

    private var downloadTasks: [ASRModelID: URLSessionDownloadTask] = [:]
    private var installTasks: [ASRModelID: Task<Void, Never>] = [:]
    private var operationGenerations: [ASRModelID: UUID] = [:]
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
        if downloadedModelIds != ids {
            downloadedModelIds = ids
        }
    }

    /// 检查模型是否已下载（响应式）
    func isDownloaded(_ modelId: ASRModelID) -> Bool {
        downloadedModelIds.contains(modelId)
    }

    /// 开始下载模型
    func download(modelId: ASRModelID) {
        let info = ModelRegistry.model(for: modelId)
        guard !(downloads[modelId]?.isActive ?? false) else { return }

        let generation = UUID()
        operationGenerations[modelId] = generation
        downloads[modelId] = .downloading(progress: 0)

        if !info.downloadFiles.isEmpty {
            let installTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.downloadAndInstallFiles(
                    modelId: modelId,
                    info: info,
                    generation: generation
                )
            }
            installTasks[modelId] = installTask
            return
        }

        guard let urlString = info.downloadURL, let url = URL(string: urlString) else {
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .failed("无效的下载地址")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600  // 1 小时超时
        let session = URLSession(configuration: config)

        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            // URLSession 临时文件只保证在 completion 返回前存在，必须在这里同步移走。
            var stagedArchive: URL?
            var stagingError: Error?
            if error == nil,
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let tempURL {
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MacRecord-\(UUID().uuidString).tar.bz2")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: stagedURL)
                    stagedArchive = stagedURL
                } catch {
                    stagingError = error
                }
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    if let stagedArchive { try? FileManager.default.removeItem(at: stagedArchive) }
                    return
                }
                guard self.operationGenerations[modelId] == generation else {
                    if let stagedArchive { try? FileManager.default.removeItem(at: stagedArchive) }
                    return
                }
                self.observations.removeValue(forKey: modelId)
                self.downloadTasks.removeValue(forKey: modelId)
                if let error {
                    self.operationGenerations.removeValue(forKey: modelId)
                    self.downloads[modelId] = (error as NSError).code == NSURLErrorCancelled
                        ? .idle
                        : .failed("下载失败: \(error.localizedDescription)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    self.operationGenerations.removeValue(forKey: modelId)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.downloads[modelId] = .failed("下载服务器返回 HTTP \(status)")
                    return
                }
                if let stagingError {
                    self.operationGenerations.removeValue(forKey: modelId)
                    self.downloads[modelId] = .failed("保存下载文件失败: \(stagingError.localizedDescription)")
                    return
                }
                guard let stagedArchive else {
                    self.operationGenerations.removeValue(forKey: modelId)
                    self.downloads[modelId] = .failed("下载文件不存在")
                    return
                }

                self.downloads[modelId] = .extracting
                let installTask = Task { @MainActor [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: stagedArchive)
                        return
                    }
                    await self.extractAndInstall(
                        modelId: modelId,
                        archiveURL: stagedArchive,
                        info: info,
                        generation: generation
                    )
                }
                self.installTasks[modelId] = installTask
            }
        }

        // 观察下载进度
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.operationGenerations[modelId] == generation else { return }
                self.downloads[modelId] = .downloading(progress: progress.fractionCompleted)
            }
        }
        observations[modelId] = observation
        downloadTasks[modelId] = task
        task.resume()
    }

    /// 取消下载
    func cancelDownload(modelId: ASRModelID) {
        operationGenerations[modelId] = UUID()
        downloadTasks[modelId]?.cancel()
        installTasks[modelId]?.cancel()
        downloadTasks.removeValue(forKey: modelId)
        installTasks.removeValue(forKey: modelId)
        observations.removeValue(forKey: modelId)
        downloads[modelId] = .idle
    }

    /// 删除已下载的模型
    func deleteModel(modelId: ASRModelID) {
        cancelDownload(modelId: modelId)
        let modelDir = ModelRegistry.modelDirectory(for: modelId)
        try? FileManager.default.removeItem(at: modelDir)
        downloads[modelId] = .idle
        refreshDownloadedModels()
    }

    // MARK: - 多文件模型安装

    private func downloadAndInstallFiles(
        modelId: ASRModelID,
        info: ASRModelInfo,
        generation: UUID
    ) async {
        let fm = FileManager.default
        let modelDir = ModelRegistry.modelDirectory(for: modelId)
        let stagingDir = ModelRegistry.modelsDirectory
            .appendingPathComponent(".staging-\(modelId.rawValue)-\(generation.uuidString)", isDirectory: true)
        let totalBytes = max(info.downloadFiles.reduce(Int64(0)) { $0 + $1.expectedSize }, 1)
        var completedBytes: Int64 = 0

        defer {
            try? fm.removeItem(at: stagingDir)
            if operationGenerations[modelId] == generation {
                installTasks.removeValue(forKey: modelId)
            }
        }

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for (index, remoteFile) in info.downloadFiles.enumerated() {
                try Task.checkCancellation()
                guard operationGenerations[modelId] == generation else { return }
                guard !remoteFile.relativePath.hasPrefix("/"),
                      !remoteFile.relativePath.split(separator: "/").contains(".."),
                      let url = URL(string: remoteFile.downloadURL) else {
                    throw ExtractError.verifyFailed("模型文件路径或下载地址无效")
                }

                downloads[modelId] = .installing("正在下载 \(index + 1)/\(info.downloadFiles.count)…")
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForResource = 7_200
                let session = URLSession(configuration: config)
                let (temporaryURL, response) = try await session.download(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw ExtractError.downloadFailed("服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }

                try Task.checkCancellation()
                let destination = stagingDir.appendingPathComponent(remoteFile.relativePath)
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: temporaryURL, to: destination)

                let attributes = try fm.attributesOfItem(atPath: destination.path)
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize == remoteFile.expectedSize else {
                    throw ExtractError.verifyFailed("\(remoteFile.relativePath) 文件大小不匹配")
                }
                let expectedHash = remoteFile.sha256
                let actualHash = try await Task.detached {
                    try Self.sha256(of: destination)
                }.value
                guard actualHash == expectedHash else {
                    throw ExtractError.verifyFailed("\(remoteFile.relativePath) SHA-256 校验失败")
                }

                completedBytes += actualSize
                downloads[modelId] = .downloading(
                    progress: min(Double(completedBytes) / Double(totalBytes), 1)
                )
            }

            try Task.checkCancellation()
            guard operationGenerations[modelId] == generation else { return }
            guard ModelRegistry.validateModelFiles(for: modelId, in: stagingDir) else {
                throw ExtractError.verifyFailed("模型文件不完整")
            }
            if fm.fileExists(atPath: modelDir.path) {
                try fm.removeItem(at: modelDir)
            }
            try fm.moveItem(at: stagingDir, to: modelDir)
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .completed
            refreshDownloadedModels()
        } catch is CancellationError {
            guard operationGenerations[modelId] == generation else { return }
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .idle
        } catch {
            guard operationGenerations[modelId] == generation else { return }
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .failed("安装失败: \(error.localizedDescription)")
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 解压安装

    private func extractAndInstall(
        modelId: ASRModelID,
        archiveURL: URL,
        info: ASRModelInfo,
        generation: UUID
    ) async {
        let modelDir = ModelRegistry.modelDirectory(for: modelId)
        let stagingDir = ModelRegistry.modelsDirectory
            .appendingPathComponent(".staging-\(modelId.rawValue)-\(generation.uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: archiveURL)
            try? fm.removeItem(at: stagingDir)
            if operationGenerations[modelId] == generation {
                installTasks.removeValue(forKey: modelId)
            }
        }

        guard operationGenerations[modelId] == generation else { return }
        do {
            try Task.checkCancellation()
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            let localArchive = stagingDir.appendingPathComponent("download.tar.bz2")
            if fm.fileExists(atPath: localArchive.path) {
                try fm.removeItem(at: localArchive)
            }
            try await Task.detached {
                try FileManager.default.moveItem(at: archiveURL, to: localArchive)
            }.value
            try Task.checkCancellation()
            guard operationGenerations[modelId] == generation else { return }

            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["xjf", localArchive.path, "-C", stagingDir.path, "--strip-components=1"],
                timeout: 1_800
            )
            try Task.checkCancellation()
            guard operationGenerations[modelId] == generation else { return }
            try? fm.removeItem(at: localArchive)

            if result.status != 0 {
                let errMsg = String(data: result.standardError, encoding: .utf8) ?? "未知解压错误"
                throw ExtractError.extractFailed(errMsg)
            }
            guard ModelRegistry.validateModelFiles(for: modelId, in: stagingDir) else {
                throw ExtractError.verifyFailed("模型文件不完整")
            }
            guard operationGenerations[modelId] == generation else { return }
            if fm.fileExists(atPath: modelDir.path) {
                try fm.removeItem(at: modelDir)
            }
            try fm.moveItem(at: stagingDir, to: modelDir)

            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .completed
            refreshDownloadedModels()
        } catch is CancellationError {
            try? fm.removeItem(at: stagingDir)
            guard operationGenerations[modelId] == generation else { return }
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .idle
        } catch {
            try? fm.removeItem(at: stagingDir)
            guard operationGenerations[modelId] == generation else { return }
            operationGenerations.removeValue(forKey: modelId)
            downloads[modelId] = .failed("安装失败: \(error.localizedDescription)")
        }
    }

    enum ExtractError: LocalizedError {
        case downloadFailed(String)
        case extractFailed(String)
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): return "下载失败: \(msg)"
            case .extractFailed(let msg): return "解压失败: \(msg)"
            case .verifyFailed(let msg): return "验证失败: \(msg)"
            }
        }
    }
}
