import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 主布局：NavigationSplitView，Apple 语音备忘录风格
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importProgress: String = ""
    @StateObject private var recordingVM = RecordingViewModel()

    var filteredRecordings: [Recording] {
        if searchText.isEmpty { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.plainText ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detailContent
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .aiff],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importAudioFile(url: url) }
            }
        }
        .overlay {
            if isImporting {
                importOverlay
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingCompleted)) { notification in
            handleRecordingCompleted(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingTextReady)) { notification in
            handleRecordingTextReady(notification)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            recordingList
            Divider()
            sidebarFooter
        }
        .navigationTitle("所有录音")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索录音…")
    }

    @ViewBuilder
    private var recordingList: some View {
        if filteredRecordings.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text("暂无录音")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $appState.selectedRecordingId) {
                ForEach(groupedRecordings, id: \.key) { date, items in
                    Section {
                        ForEach(items) { recording in
                            RecordingRow(recording: recording)
                                .tag(recording.id)
                        }
                    } header: {
                        Text(date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// 按日期分组
    private var groupedRecordings: [(key: String, value: [Recording])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecordings) { recording -> String in
            if calendar.isDateInToday(recording.createdAt) {
                return "今天"
            } else if calendar.isDateInYesterday(recording.createdAt) {
                return "昨天"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()),
                      recording.createdAt > weekAgo {
                formatter.dateFormat = "EEEE"
                return formatter.string(from: recording.createdAt)
            } else if calendar.component(.year, from: recording.createdAt) == calendar.component(.year, from: Date()) {
                formatter.dateFormat = "M月d日"
                return formatter.string(from: recording.createdAt)
            } else {
                formatter.dateFormat = "yyyy年M月"
                return formatter.string(from: recording.createdAt)
            }
        }

        return grouped.sorted { a, b in
            let aDate = filteredRecordings.first(where: { grouped[a.key]?.contains($0) == true })?.createdAt ?? Date.distantPast
            let bDate = filteredRecordings.first(where: { grouped[b.key]?.contains($0) == true })?.createdAt ?? Date.distantPast
            return aDate > bDate
        }
    }

    // MARK: - Sidebar Footer

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            if !appState.isRecording {
                Picker("", selection: $appState.audioSource) {
                    ForEach(AudioSourceType.allCases) { source in
                        Label(source.displayName, systemImage: source.iconName)
                            .tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)
            }

            if appState.isRecording {
                // ★ 录音中：醒目的录音状态区域
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        // 录音状态圆点（带脉冲动画）
                        Circle()
                            .fill(appState.isPaused ? .orange : .red)
                            .frame(width: 16, height: 16)
                            .shadow(color: (appState.isPaused ? Color.orange : Color.red).opacity(0.5), radius: 4)

                        Text(recordingVM.formattedDuration)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .monospacedDigit()

                        Spacer()

                        if appState.audioSource == .microphone {
                            Button {
                                Task { await appState.togglePauseRecording() }
                            } label: {
                                Image(systemName: appState.isPaused ? "play.fill" : "pause.fill")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            Task { await appState.stopRecordingSession() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.body.bold())
                                Text("完成")
                                    .font(.body.weight(.semibold))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.green)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // ASR 实时文本预览（最后 2 行）
                    if !recordingVM.liveText.isEmpty {
                        Text(lastLinesPreview(recordingVM.liveText, count: 2))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // DRM 保护提示（Self 模式下检测到保护应用时）
                    if appState.audioSource == .systemAudio,
                       let warning = appState.systemAudioRecorder?.drmWarning {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Button {
                    Task {
                        await appState.startRecordingSession()
                        if appState.isRecording {
                            recordingVM.bind(appState: appState)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(appState.audioSource == .systemAudio ? .blue : .red)
                                .frame(width: 32, height: 32)
                            Circle()
                                .fill((appState.audioSource == .systemAudio ? Color.blue : Color.red).opacity(0.3))
                                .frame(width: 40, height: 40)
                            Image(systemName: appState.audioSource == .systemAudio ? "speaker.wave.3.fill" : "mic.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                        Text(appState.audioSource == .systemAudio ? "开始 Self 记录" : "开始录音")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!appState.isModelReady)
                .opacity(appState.isModelReady ? 1 : 0.4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .onChange(of: appState.isRecording) { _, isRecording in
            if isRecording {
                recordingVM.bind(appState: appState)
            } else {
                recordingVM.unbind()
            }
        }
    }

    private func lastLinesPreview(_ text: String, count: Int) -> String {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let selectedId = appState.selectedRecordingId,
           let recording = recordings.first(where: { $0.id == selectedId }) {
            DetailView(recording: recording)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.quaternary)
            Text("选择一个录音或开始新录音")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("点击左下角的红色按钮开始录音，\n或使用工具栏导入音频文件")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import Overlay

    @ViewBuilder
    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                Text(importProgress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showFileImporter = true
            } label: {
                Label("导入文件", systemImage: "square.and.arrow.down")
            }
            .help("导入 MP3/M4A/WAV 等音频文件")

            if let selectedId = appState.selectedRecordingId,
               recordings.contains(where: { $0.id == selectedId }) {
                Button {
                    if let r = recordings.first(where: { $0.id == selectedId }) {
                        ExportManager.shared.export(recording: r)
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .help("导出录音")

                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除录音")
            }

            Divider()

            // AI 模型选择器
            aiModelPicker

            SettingsLink {
                Label("AI 配置", systemImage: "gear")
            }
            .help("AI 模型配置")
        }

        ToolbarItem(placement: .status) {
            // ★ ASR 模型状态栏 — 点击可切换模型
            Menu {
                ForEach(ASREngineType.allCases) { engine in
                    Button {
                        Task { await appState.switchASREngine(to: engine) }
                    } label: {
                        HStack {
                            Text(engine.displayName)
                            if appState.asrConfigStore.selectedEngine == engine {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isModelReady ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Image(systemName: appState.asrConfigStore.selectedEngine.iconName)
                        .font(.caption)
                    Text(appState.modelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private var aiModelPicker: some View {
        let models = appState.llmConfigStore.models
        if models.isEmpty {
            Text("未配置模型")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Picker("AI 模型", selection: Binding(
                get: { appState.llmConfigStore.activeModelId },
                set: { appState.llmConfigStore.setActiveModel(id: $0) }
            )) {
                ForEach(models) { model in
                    Text(model.label.isEmpty ? model.modelName : model.label)
                        .tag(model.id)
                }
            }
            .frame(maxWidth: 160)
        }
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let id = appState.selectedRecordingId,
              let recording = recordings.first(where: { $0.id == id }) else { return }
        appState.selectedRecordingId = nil
        if let audioPath = recording.audioPath {
            AudioFileManager.shared.deleteAudioFile(relativePath: audioPath)
        }
        modelContext.delete(recording)
    }

    private func importAudioFile(url: URL) async {
        isImporting = true
        importProgress = "正在导入…"

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent

        let recording = Recording(
            title: title,
            originalFilename: url.lastPathComponent,
            createdAt: Date(),
            updatedAt: Date()
        )
        modelContext.insert(recording)

        if let storedPath = AudioFileManager.shared.storeAudioFile(from: url, hash: recording.id.uuidString) {
            recording.audioPath = storedPath
        }

        if let bridge = appState.asrBridge, appState.isModelReady,
           appState.asrConfigStore.selectedEngine == .senseVoice {
            importProgress = "正在转录…"
            do {
                let result = try await bridge.transcribeFile(audioPath: url.path, language: "auto")
                recording.plainText = result.plainText
                recording.timestampText = result.timestampText
                recording.detectedLanguage = result.detectedLanguage
                recording.duration = result.duration
                recording.updatedAt = Date()
            } catch {
                importProgress = "转录失败: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(2))
            }
        } else if let service = appState.nativeASRService, appState.isModelReady,
                  appState.asrConfigStore.selectedEngine == .senseVoiceNative {
            importProgress = "正在转录…"
            do {
                let result = try await service.transcribeFile(audioPath: url.path, language: "auto")
                recording.plainText = result.plainText
                recording.detectedLanguage = result.detectedLanguage
                recording.updatedAt = Date()
            } catch {
                importProgress = "转录失败: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(2))
            }
        }

        appState.selectedRecordingId = recording.id
        isImporting = false
    }

    private func handleRecordingCompleted(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let title = info["title"] as? String ?? "新录音"
        let plainText = info["plainText"] as? String ?? ""
        let timestampText = info["timestampText"] as? String ?? ""
        let detectedLang = info["detectedLanguage"] as? String
        let duration = info["duration"] as? TimeInterval ?? 0
        let recordingURL = info["recordingURL"] as? URL
        let sessionId = info["sessionId"] as? UUID

        let recording = Recording(
            title: title,
            duration: duration,
            timestampText: timestampText,
            plainText: plainText.isEmpty ? nil : plainText,
            detectedLanguage: detectedLang,
            createdAt: Date(),
            updatedAt: Date()
        )
        // 保存 sessionId 以便后续补充文本
        if let sid = sessionId {
            recording.fileHash = sid.uuidString
        }
        modelContext.insert(recording)

        if let url = recordingURL {
            if let storedPath = AudioFileManager.shared.storeAudioFile(from: url, hash: recording.id.uuidString) {
                recording.audioPath = storedPath
            }
        }

        appState.selectedRecordingId = recording.id
    }

    private func handleRecordingTextReady(_ notification: Notification) {
        guard let info = notification.userInfo,
              let sessionId = info["sessionId"] as? UUID else { return }
        let plainText = info["plainText"] as? String ?? ""
        let timestampText = info["timestampText"] as? String ?? ""
        let detectedLang = info["detectedLanguage"] as? String

        // 找到对应的录音记录并更新文本
        if let recording = recordings.first(where: { $0.fileHash == sessionId.uuidString }) {
            if !plainText.isEmpty {
                recording.plainText = plainText
            }
            if !timestampText.isEmpty {
                recording.timestampText = timestampText
            }
            if let lang = detectedLang, !lang.isEmpty {
                recording.detectedLanguage = lang
            }
            recording.updatedAt = Date()
        }
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 8) {
                if let duration = recording.duration, duration > 0 {
                    Label(formatDuration(duration), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if recording.plainText?.isEmpty == false {
                    Image(systemName: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if recording.summaries?.isEmpty == false {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.6))
                }

                Spacer()

                Text(timeString(recording.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(max(0, s))
        let m = total / 60, sec = total % 60
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, m % 60, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: date)
    }
}
