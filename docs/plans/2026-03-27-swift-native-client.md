# Mac-Record: Swift 原生客户端实施计划

> **目标**：彻底抛弃 pywebview + FastAPI + 浏览器前端，用 Swift 构建 macOS 原生语音转写客户端。
> **生成时间**：2026-03-27
> **核心原则**：零 Web 组件。所有 UI 用 SwiftUI，所有网络用 URLSession，ASR 通过子进程调用 Python。

---

## 一、架构总览

```
Mac-Record.app (Swift / SwiftUI / macOS 14+)
│
├── 📱 UI 层 (SwiftUI)
│   ├── SidebarView          — 录音列表 + 搜索 + 录音按钮
│   ├── DetailView            — 历史详情：波形 + 播放 + ASR文本 + AI纪要
│   ├── RecordingView         — 录音中：实时波形 + 实时ASR文本
│   ├── FileImportView        — 文件上传转录进度
│   └── SettingsView          — AI 模型配置（macOS Settings 风格）
│
├── 🎙️ 音频层 (AVFoundation)
│   ├── AudioRecorder         — AVAudioEngine 实时录音
│   ├── AudioPlayer           — AVPlayer 音频播放
│   └── AudioFileConverter    — 格式转换（M4A/MP3/WAV → 16kHz WAV）
│
├── 🧠 ASR 引擎层 (Python 子进程)
│   ├── ASRBridge             — Swift ↔ Python 通信协议（JSON over stdin/stdout）
│   ├── asr_server.py         — 精简版 Python ASR 服务（从 whisper_env 提取）
│   │   ├── sensevoice_core   — FunASR SenseVoiceSmall + FSMN-VAD
│   │   ├── audio_enhance     — 音频预处理（高通滤波+谱减法+动态压缩）
│   │   └── speaker_diarize   — CAM++ 说话人分离
│   └── ASRSessionManager     — 管理实时/文件转录会话状态机
│
├── 🤖 AI 层 (Swift 原生)
│   ├── LLMService            — URLSession 直接调用 LLM API（OpenAI 兼容协议）
│   ├── LLMConfigStore        — AI 模型配置 CRUD（JSON 文件 + Keychain 存 API Key）
│   ├── PromptTemplateStore   — Prompt 模板管理
│   └── SummaryGenerator      — 长文本分段摘要 + 合并策略
│
├── 💾 数据层
│   ├── RecordingStore        — SwiftData 模型（录音历史 + AI纪要）
│   └── AudioFileManager      — 音频文件存储管理（~/.mac-record/audio/）
│
└── 🔧 基础设施
    ├── AppDelegate           — 应用生命周期 + 子进程管理
    ├── KeychainHelper        — API Key 安全存储
    └── ExportManager         — NSSavePanel 导出（WAV/TXT/ZIP）
```

---

## 二、Swift ↔ Python ASR 通信协议

**核心思路**：Python 以**长驻子进程**运行，通过 **JSON-RPC over stdin/stdout** 通信。

### 2.1 协议格式

```
Swift → Python (stdin):
  {"id": 1, "method": "transcribe_file", "params": {"audio_path": "/tmp/audio.wav", "language": "auto"}}

Python → Swift (stdout):
  {"id": 1, "result": {"segments": [...], "plain_text": "...", "detected_lang": "zh"}}

实时模式（流式）:
  Swift → Python:  {"id": 2, "method": "realtime_start", "params": {"language": "auto"}}
  Swift → Python:  {"id": 3, "method": "realtime_feed", "params": {"audio_base64": "..."}}
                    （每 0.8 秒发一次 PCM chunk）
  Python → Swift:  {"id": 3, "result": {"text": "你好", "is_final": false}}
  Swift → Python:  {"id": 99, "method": "realtime_stop", "params": {}}
  Python → Swift:  {"id": 99, "result": {"final_text": "...", "timestamp_text": "..."}}
```

### 2.2 Python 端支持的方法

| 方法 | 说明 | 来源模块 |
|------|------|----------|
| `init_models` | 加载 ASR/VAD 模型 | sensevoice_core |
| `get_model_status` | 模型加载状态 | sensevoice_core |
| `transcribe_file` | 文件转录（VAD+ASR+说话人分离） | sensevoice_core + speaker_diarization |
| `realtime_start` | 开始实时转写会话 | sensevoice_core |
| `realtime_feed` | 喂入实时音频 chunk | sensevoice_core |
| `realtime_stop` | 结束实时转写 | sensevoice_core |
| `diarize` | 对已有音频执行说话人分离 | speaker_diarization |

### 2.3 为什么不用 HTTP

- stdin/stdout 零网络开销，延迟更低
- 不占用端口，不存在端口冲突
- 子进程生命周期与 app 绑定，关闭 app 自动 kill
- 不需要 CORS、认证等 Web 层的复杂性

---

## 三、数据模型 (SwiftData)

```swift
@Model
class Recording {
    var id: UUID
    var title: String
    var originalFilename: String?
    var audioPath: String?           // 相对路径
    var fileHash: String?
    var duration: Double?            // 秒
    var language: String?
    var timestampText: String?       // [00:01 -> 00:05] 你好
    var plainText: String?           // 纯文本
    var detectedLanguage: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var summaries: [AISummary]
}

@Model
class AISummary {
    var id: UUID
    var prompt: String
    var summary: String
    var modelName: String?
    var createdAt: Date

    var recording: Recording?
}
```

### 数据迁移

从现有 SQLite (`whisper_history.db`) 迁移：
- 读取 `transcription_history` 表 → 创建 `Recording` 实例
- 读取 `ai_summaries` 表 → 创建 `AISummary` 实例
- 复制 `.whisper_audio_storage/` 下的音频文件到新目录

---

## 四、从现有代码复用的部分

### 4.1 直接复用（打包进 app bundle）

| 文件 | 用途 | 修改 |
|------|------|------|
| `sensevoice_core.py` | ASR/VAD 引擎 | 剥离 Web 相关代码，只保留核心函数 |
| `audio_enhance.py` | 音频预处理 | 原样复用 |
| `speaker_diarization.py` | 说话人分离 | 原样复用 |

### 4.2 用 Swift 重写（不需要 Python）

| 原 Python 模块 | Swift 替代 |
|---------------|-----------|
| `sensevoice_ai.py` (LLM 调用) | `LLMService.swift` — URLSession |
| `sensevoice_db.py` (SQLite) | SwiftData |
| `sensevoice_background.py` (任务调度) | Swift `Task` + `AsyncStream` |
| `services/session_manager.py` | Swift `@Observable` 状态管理 |
| `services/pubsub.py` | Combine / AsyncStream |
| `audio_compress.py` | AVAssetExportSession 或 ffmpeg CLI |
| 所有 `routers/*.py` | 不需要，UI 直接调用 Service 层 |
| 所有 `frontend/*` | SwiftUI 原生视图 |

### 4.3 完全丢弃

- `main_app.py` (pywebview 壳)
- `native_audio.py` (Python AVPlayer bridge)
- `native_recording.py` (Python AVAudioEngine bridge)
- `app_api.py` (FastAPI 入口)
- `start_app.sh`
- 所有 `frontend/` HTML/JS/CSS

---

## 五、AI 配置迁移

从现有 `ai_config.json` 迁移：
- 已验证模型列表 → Swift `LLMConfigStore`
- API Key → macOS Keychain（不再明文存储）
- Prompt 模板 → Swift `PromptTemplateStore`

现有配置：
- DeepSeek (deepseek-chat) — 活跃模型
- S3-Qwen (远程)
- qwen3.5-4b-mlx (本地 LM Studio)

预设服务商保持不变：DeepSeek / Gemini / 通义千问 / MiniMax / OpenAI / 自定义

---

## 六、任务拆分（按优先级排序）

### Phase 1: 项目骨架 + ASR 桥接（核心通路）

**目标**：能录音 → ASR 转写 → 显示文本

| # | 任务 | 预估 |
|---|------|------|
| 1.1 | 创建 Xcode 项目（SwiftUI, macOS 14+），配置 Info.plist 麦克风权限 | 小 |
| 1.2 | 编写 `asr_server.py`：从 whisper_env 提取精简版 ASR 服务，实现 JSON-RPC over stdin/stdout | 中 |
| 1.3 | 编写 `ASRBridge.swift`：管理 Python 子进程生命周期 + JSON-RPC 通信 | 中 |
| 1.4 | 编写 `AudioRecorder.swift`：AVAudioEngine 实时录音，输出 16kHz PCM | 中 |
| 1.5 | 编写 `RecordingView.swift`：录音中视图，实时显示 ASR 文本 | 中 |
| 1.6 | 端到端验证：录音 → ASR → 文本显示 | 小 |

### Phase 2: 数据持久化 + 历史管理

**目标**：录音结果保存、历史列表、详情查看

| # | 任务 | 预估 |
|---|------|------|
| 2.1 | SwiftData 模型定义 + 数据库初始化 | 小 |
| 2.2 | `AudioFileManager.swift`：音频文件存储管理 | 小 |
| 2.3 | `SidebarView.swift`：录音列表 + 搜索 | 中 |
| 2.4 | `DetailView.swift`：历史详情（文本展示 + 播放控件） | 中 |
| 2.5 | `AudioPlayer.swift`：AVPlayer 封装，播放/暂停/快进 | 小 |
| 2.6 | 从旧 SQLite 数据库迁移历史数据 | 小 |

### Phase 3: 文件上传转录

**目标**：导入 MP3/M4A/WAV 等文件 → ASR → 保存

| # | 任务 | 预估 |
|---|------|------|
| 3.1 | `AudioFileConverter.swift`：使用 AVFoundation 将各格式转为 16kHz WAV | 中 |
| 3.2 | `FileImportView.swift`：NSOpenPanel 选择文件 + 转录进度 | 中 |
| 3.3 | asr_server.py 实现 `transcribe_file` 方法（含说话人分离） | 中 |
| 3.4 | 端到端验证：导入 M4A → 转录 → 保存到历史 | 小 |

### Phase 4: AI 纪要生成

**目标**：ASR 文本 → LLM 生成会议纪要 → Markdown 渲染 → 复制

| # | 任务 | 预估 |
|---|------|------|
| 4.1 | `LLMService.swift`：URLSession 调用 OpenAI 兼容 API（同步+流式） | 中 |
| 4.2 | `LLMConfigStore.swift`：多模型配置 + Keychain 存储 API Key | 中 |
| 4.3 | `SummaryGenerator.swift`：长文本分段策略 + 结果合并 | 中 |
| 4.4 | `PromptTemplateStore.swift`：Prompt 模板 CRUD | 小 |
| 4.5 | DetailView 扩展：AI 纪要 Tab + Markdown 渲染 + 复制按钮 | 中 |
| 4.6 | `SettingsView.swift`：AI 模型配置界面（预设服务商+自定义+测试连接） | 中 |

### Phase 5: 补全功能 + 打磨

**目标**：补转录、说话人分离、导出、波形、数据迁移

| # | 任务 | 预估 |
|---|------|------|
| 5.1 | 波形可视化：静态波形（Core Graphics 绘制）+ 实时波形 | 中 |
| 5.2 | 导出功能：NSSavePanel，支持 WAV/ASR TXT/LLM TXT/ZIP | 中 |
| 5.3 | 补转录：对有音频无文本的记录重新 ASR | 小 |
| 5.4 | 说话人分离 UI：按钮 + 结果标注显示 | 小 |
| 5.5 | 从旧 whisper_env 完整迁移数据（音频文件+历史+AI纪要+配置） | 中 |
| 5.6 | App 打包：.app bundle 包含 Python 环境 + 模型，DMG 分发 | 大 |

---

## 七、关键技术决策

### 7.1 Python 环境打包

方案：**app bundle 内嵌 Python venv**
- 在 `Mac-Record.app/Contents/Resources/python_env/` 下打包精简后的 venv
- 只包含 FunASR、scipy、numpy、librosa 及模型文件
- App 启动时自动检测并初始化 Python 子进程

### 7.2 音频格式支持

Swift AVFoundation 原生支持的格式：
- WAV, M4A, MP3, CAF, AIFF, AAC, FLAC
- 几乎覆盖所有常见格式，不需要 ffmpeg

使用 `AVAudioFile` + `AVAudioConverter` 统一转换为 16kHz mono PCM WAV。

### 7.3 实时录音架构

```
AVAudioEngine (installTap, 16kHz mono)
    ↓ PCM buffer (0.8s)
ASRBridge.realtime_feed(base64 PCM)
    ↓ stdin → Python subprocess
sensevoice_core.handle_realtime_stream()
    ↓ stdout → JSON
RecordingViewModel.text = result.text
    ↓ @Published
RecordingView (SwiftUI auto-refresh)
```

### 7.4 macOS 版本兼容

- **最低 macOS 14 (Sonoma)**：支持 SwiftData + 最新 SwiftUI
- 如需兼容 macOS 13：退回 Core Data + 老式 SwiftUI

---

## 八、目录结构

```
Mac-Record/
├── Mac-Record.xcodeproj
├── Mac-Record/
│   ├── App/
│   │   ├── MacRecordApp.swift          — @main 入口
│   │   └── AppDelegate.swift           — 子进程管理 + 生命周期
│   ├── Views/
│   │   ├── ContentView.swift           — NavigationSplitView 主布局
│   │   ├── SidebarView.swift           — 录音列表
│   │   ├── DetailView.swift            — 历史详情
│   │   ├── RecordingView.swift         — 录音中视图
│   │   ├── FileImportView.swift        — 文件导入
│   │   ├── SettingsView.swift          — AI 配置
│   │   └── Components/
│   │       ├── WaveformView.swift      — 波形
│   │       ├── MarkdownView.swift      — Markdown 渲染
│   │       └── PlaybackControls.swift  — 播放控件
│   ├── Models/
│   │   ├── Recording.swift             — SwiftData 模型
│   │   └── AISummary.swift             — SwiftData 模型
│   ├── Services/
│   │   ├── ASRBridge.swift             — Python 子进程通信
│   │   ├── AudioRecorder.swift         — AVAudioEngine 录音
│   │   ├── AudioPlayer.swift           — AVPlayer 播放
│   │   ├── AudioFileConverter.swift    — 格式转换
│   │   ├── LLMService.swift            — LLM API 调用
│   │   ├── SummaryGenerator.swift      — 纪要生成
│   │   └── ExportManager.swift         — 导出
│   ├── Stores/
│   │   ├── RecordingStore.swift        — 数据 CRUD
│   │   ├── LLMConfigStore.swift        — AI 配置
│   │   └── PromptTemplateStore.swift   — Prompt 模板
│   ├── Utilities/
│   │   ├── KeychainHelper.swift        — Keychain 存取
│   │   └── AudioFileManager.swift      — 文件管理
│   ├── Resources/
│   │   └── python_env/                 — 打包的 Python 环境
│   │       ├── asr_server.py           — JSON-RPC ASR 服务
│   │       ├── sensevoice_core.py      — ASR/VAD 核心
│   │       ├── audio_enhance.py        — 音频预处理
│   │       └── speaker_diarization.py  — 说话人分离
│   └── Info.plist                      — 麦克风权限声明
├── docs/
│   ├── feature-audit.md
│   └── plans/
│       └── 2026-03-27-swift-native-client.md  — 本文件
└── README.md
```

---

## 九、验收标准

1. **实时录音转写**：点击录音 → 实时显示 ASR 文本 → 停止 → 保存，全流程原生 UI
2. **文件导入转录**：NSOpenPanel 选择 MP3/M4A/WAV → 转录进度显示 → 保存到历史
3. **AI 纪要**：选择录音 → 点击"生成纪要" → LLM 返回 Markdown → 渲染显示 → 可复制
4. **复制**：ASR 原文和 AI 纪要均可一键复制
5. **导出**：NSSavePanel 导出 WAV/TXT/ZIP
6. **零 Web 组件**：整个 app 不包含任何 WKWebView、HTML、JS、CSS
7. **API Key 安全**：存储在 macOS Keychain，不明文写入磁盘
8. **可分发**：.app bundle 或 DMG，双击即可运行
