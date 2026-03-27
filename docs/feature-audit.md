# SenseVoice 语音转写工作台 — 功能盘点 & 逻辑漏洞检查

> 生成时间：2026-03-27  
> 目的：为 Swift 原生客户端重构提供完整的功能清单、已知问题和架构风险评估  
> 来源项目：`~/Desktop/whisper_env/`

---

## 一、项目概览

| 维度 | 说明 |
|------|------|
| **产品定位** | macOS 桌面语音转写工作台，Apple 语音备忘录风格 |
| **技术栈** | FastAPI + pywebview + FunASR (SenseVoiceSmall + FSMN-VAD) + LLM API |
| **运行模式** | 双模式：(1) 原生桌面 `main_app.py` (pywebview) (2) 浏览器 `localhost:8000` |
| **版本号** | 2.0.0 |

### 代码量统计

| 层 | 行数 | 文件数 |
|---|---|---|
| Python 后端 | ~6,000 行 | 11 个根 + 7 个 routers + 3 个 services |
| 前端 (HTML/JS/CSS) | ~5,800 行 | 5 个 JS + 1 个 HTML + 1 个 CSS |
| pywebview 壳 | 752 行 | main_app.py + native_audio.py + native_recording.py |

---

## 二、完整功能清单

### 2.1 核心功能

| # | 功能 | 实现位置 | 说明 |
|---|------|---------|------|
| 1 | **实时录音 + 实时转写** | recorder.js + recordings.py + sensevoice_background.py | 边录边转：麦克风采集 → 实时 VAD+ASR → 文本实时显示 |
| 2 | **文件上传转录** | files.py + sensevoice_background.py | 上传已有音频文件 → 后台 VAD+ASR+说话人分离+LLM优化 |
| 3 | **历史记录 CRUD** | history.py + sensevoice_db.py | SQLite 存储，列表/详情/删除/重命名/搜索 |
| 4 | **AI 纪要生成** | ai.py + sensevoice_ai.py | 支持长文本自动分段（8K/16K 字符阈值），多服务商 |
| 5 | **说话人分离** | speaker_diarization.py + history.py | CAM++ 嵌入 + AHC 聚类 |
| 6 | **补转录** | history.py | 对有音频无文本的记录重新 ASR |
| 7 | **导出** | export.py + main_app.py | WAV/ASR(TXT)/LLM(TXT)/全部(ZIP)，原生另存为对话框 |
| 8 | **多模型选择** | sensevoice_ai.py + ai.py | validated_models 列表，toolbar 下拉切换 |
| 9 | **本地模型健康检查** | sensevoice_ai.py | 30 秒轮询，离线模型标记 ⚠️ |

### 2.2 UI 功能

| # | 功能 | 说明 |
|---|------|------|
| 11 | **三视图切换** | empty / detail / recording |
| 12 | **静态波形** | 服务端采样 300 点，Canvas 渲染 |
| 13 | **实时波形** | 音频电平推送 → Canvas |
| 14 | **播放控制** | 播放/暂停/快进15s/后退15s，双模式（AVPlayer / HTML5 Audio） |
| 15 | **搜索** | 标题模糊搜索，300ms 防抖 |
| 16 | **Markdown 纪要渲染** | 轻量级 MD→HTML 转换（标题/加粗/列表/分隔线） |
| 17 | **复制到剪贴板** | ASR 原文 / AI 纪要 |
| 18 | **重命名** | 双击 / 按钮编辑标题 |
| 19 | **AI 配置弹窗** | macOS Settings 风格，6 预设服务商 + 自定义 |
| 20 | **调试面板** | Ctrl+D 切换，分类着色日志 |

### 2.3 预设 AI 服务商

1. DeepSeek (deepseek-chat, deepseek-reasoner)
2. Google Gemini (gemini-2.5-flash, gemini-2.0-flash, gemini-2.5-pro)
3. 通义千问 (qwen-turbo, qwen-plus, qwen-max)
4. MiniMax (MiniMax-Text-01, abab6.5s-chat)
5. OpenAI (gpt-4o-mini, gpt-4o, gpt-4.1-mini)
6. 自定义（OpenAI 兼容接口）

### 2.4 通信通道

| 通道 | 用途 | 协议 |
|------|------|------|
| REST | CRUD + AI + 导出 | HTTP fetch |
| WebSocket | 实时录音双向（上行音频 + 下行状态/电平/文本） | WS |
| SSE | 文件转录进度推送 | EventSource |

### 2.5 pywebview Bridge 方法（13 个）

| 方法 | 用途 |
|------|------|
| `audio_load(path)` | AVPlayer 加载音频 |
| `audio_play()` | 播放 |
| `audio_pause()` | 暂停 |
| `audio_seek(seconds)` | 跳转 |
| `audio_stop()` | 停止 |
| `audio_get_state()` | 轮询播放状态 (200ms) |
| `mic_list_devices()` | 枚举系统麦克风 |
| `mic_start(session_id, device_uid, wav_dir)` | 启动原生录音 |
| `mic_pause()` | 暂停录音 |
| `mic_resume()` | 恢复录音 |
| `mic_stop()` | 停止录音 |
| `mic_get_level()` | 获取音量电平 |
| `export_file(historyId, type, suggestedName)` | 原生另存为对话框导出 |

---

## 三、API 端点清单（37 个）

### 录音 (recordings.py)
- `POST /api/recordings/start` — 启动录音（browser/native/ffmpeg 三模式）
- `POST /api/recordings/{id}/stop` — 停止录音
- `POST /api/recordings/{id}/pause` — 暂停录音
- `POST /api/recordings/{id}/resume` — 恢复录音
- `POST /api/recordings/{id}/save` — 保存到历史（幂等）
- `GET /api/recordings/{id}/snapshot` — 获取会话快照
- `GET /api/recordings/active` — 列出活跃会话
- `GET /api/recordings/devices` — 列出音频设备
- `WS /api/recordings/ws/realtime/{id}` — WebSocket 双向通信

### 文件 (files.py)
- `POST /api/files/upload` — 上传音频+启动转录
- `GET /api/files/{id}/snapshot` — 转录进度快照
- `GET /api/files/{id}/events` — SSE 实时进度

### 历史 (history.py)
- `GET /api/history/` — 列表（支持 keyword 搜索）
- `GET /api/history/{id}` — 详情
- `DELETE /api/history/{id}` — 删除
- `PATCH /api/history/{id}/title` — 重命名
- `GET /api/history/{id}/waveform` — 波形数据
- `GET /api/history/{id}/audio_path` — 音频本地路径
- `POST /api/history/{id}/diarize` — 说话人分离
- `POST /api/history/{id}/retranscribe` — 补转录
- `POST /api/history/{id}/save-transcription` — 保存转录结果

### AI (ai.py)
- `GET /api/ai/config` — 获取 AI 配置
- `POST /api/ai/config` — 保存 AI 配置
- `POST /api/ai/test-connection` — 测试连接
- `POST /api/ai/optimize` — ASR 文本优化
- `POST /api/ai/summary` — 生成 AI 纪要
- `GET /api/ai/summaries/{id}` — 查询纪要
- `GET /api/ai/validated-models` — 已验证模型列表
- `GET /api/ai/validated-models/health` — 模型健康检查
- `POST /api/ai/validated-models` — 添加模型
- `DELETE /api/ai/validated-models/{id}` — 删除模型
- `POST /api/ai/active-model` — 切换活跃模型
- `GET /api/ai/local-models` — 检测本地 LLM

### Prompts (prompts.py)
- `GET /api/prompts/` — 列出模板
- `GET /api/prompts/{name}` — 获取模板
- `POST /api/prompts/` — 创建/更新
- `DELETE /api/prompts/{name}` — 删除

### 导出 (export.py)
- `GET /api/export/{id}/audio` — 导出 WAV
- `GET /api/export/{id}/asr` — 导出 ASR TXT
- `GET /api/export/{id}/llm` — 导出 LLM TXT
- `GET /api/export/{id}/all` — 全部 ZIP

### 模型状态 (app_api.py)
- `GET /api/model/status` — ASR 模型加载状态

---

## 四、数据流架构

### 4.1 实时录音 + 实时转写
```
麦克风 → 音频采集 → queue.Queue → background thread
    ↓                                    ↓
  波形显示                    handle_realtime_stream
                                ↓          ↓
                          VAD → ASR → 四层文本模型
                                ↓
                      SessionManager.update()
                                ↓
                        PubSub.publish()
                                ↓
                        WebSocket → 前端实时显示
```
> 底层实现：原生模式用 AVAudioEngine，浏览器回退模式用 getUserMedia + WebSocket 上行

### 4.2 文件上传转录
```
上传文件 → POST /api/files/upload → 保存临时文件
                    ↓
        background thread: load_audio → VAD → 说话人分离 → ASR (逐段) → LLM 优化
                    ↓
        manifest.json 持久化进度 → SSE 推送 → 前端
```

### 4.3 AI 纪要
```
点击"生成 AI 纪要" → POST /api/ai/summary
     ↓
asyncio.to_thread(generate_ai_summary_chunked)
     ↓
长文本 > 阈值? → 按段落分割 → 逐段调用 LLM → 合并
     ↓
保存到 ai_summaries 表 → 返回前端 → Markdown 渲染
```

---

## 五、已知逻辑问题 & 漏洞

### 🔴 严重（影响功能正确性）

| # | 问题 | 位置 | 详情 |
|---|------|------|------|
| 1 | **导出功能不工作** | ui-components.js + main_app.py | pywebview WKWebView 拦截 `window.open`。已改为原生另存为对话框，但 pywebview 的 `create_file_dialog(SAVE_DIALOG)` 在某些版本有 bug。**根本原因是 pywebview 架构限制。** |
| 2 | **麦克风权限弹窗** | app.js | WKWebView 下 `isNativeApp()` 检测有时序问题，走入 `getUserMedia` 路径触发浏览器权限弹窗。虽然加了 2 秒等待，但不够可靠。**根本原因是 pywebview bridge 注入时序不确定。** |
| 3 | **LLM 批处理模式不一致** | sensevoice_background.py | 浏览器模式启用了 `_try_llm_batch_trigger()`（实时 LLM 润色），但 ffmpeg 管道模式和源文件模式已禁用（注释掉了）。三种模式行为不一致。 |
| 4 | **导出音频后缀假设** | export.py:60 | 始终用 `.wav` 后缀导出，但实际文件可能已被 `audio_compress.py` 转为 `.mp3`。会导致下载的文件后缀与实际格式不匹配。 |

### 🟡 中等（影响可靠性）

| # | 问题 | 位置 | 详情 |
|---|------|------|------|
| 5 | **`_retranscribing` 无锁保护** | routers/history.py:335 | `_retranscribing` dict 做防重复锁，但多线程并发时可能竞态。虽然 CPython GIL 提供了一定保护，但不严谨。 |
| 6 | **WAV 数据追加无锁** | native_recording.py:322 | `self._wav_chunks.append()` 在音频回调线程中执行，`self._wav_chunks` 没有锁保护。 |
| 7 | **`_savingInProgress` 60 秒超时安全网** | app.js:1003 | 如果保存流程异常卡住，需要 60 秒才能自动重置。这期间用户无法再次保存。 |
| 8 | **SSE 轮询固定 1s** | files.py:140 | 固定 `asyncio.sleep(1.0)` 轮询 manifest.json，大量并发任务可能产生 IO 压力。 |
| 9 | **WebSocket 重连无上限通知** | api.js | 指数退避到 16s 后不再增加，但不通知用户连接已断。 |
| 10 | **模型状态轮询停止条件不够** | app.js | `pollModelStatus` 在 `vad_loaded` 后停止，但如果模型加载失败永远不会停止轮询。 |

### 🟢 低（改善体验）

| # | 问题 | 位置 | 详情 |
|---|------|------|------|
| 11 | **搜索仅限标题** | sensevoice_db.py:344 | 只对 `title` 做 LIKE 模糊搜索，不支持全文搜索（plain_text 未纳入）。 |
| 12 | **API Key 明文存储** | ai_config.json | API Key 以明文保存在磁盘（API 层有脱敏返回，但文件本身未加密）。 |
| 13 | **CORS 全开** | app_api.py:78 | `allow_origins=["*"]`，本地应用可以接受，但如果暴露到网络存在安全风险。 |
| 14 | **`audio_path` 暴露绝对路径** | history.py:243 | `GET /api/history/{id}/audio_path` 返回服务器绝对路径，浏览器模式也可访问。 |
| 15 | **删除历史不级联删除 AI 纪要** | sensevoice_db.py:199 | SQLite 表有 `ON DELETE CASCADE` 声明，但实际 `DELETE FROM transcription_history` 时 SQLite 默认不启用外键约束。 |

---

## 六、pywebview 架构限制汇总（迁移动因）

这些问题**不是代码 bug**，而是 pywebview + WKWebView 架构的天然限制，无法通过修补代码彻底解决：

| # | 问题 | 尝试过的修复 | 结果 |
|---|------|-------------|------|
| 1 | 麦克风权限弹窗 | bridge 等待循环 (2s) | 不稳定，时序问题依然存在 |
| 2 | `window.open` 被拦截 | 改 `<a download>` | WKWebView 不支持 `<a download>` |
| 3 | 文件下载不工作 | 原生另存为对话框 | 可用但体验不如原生 |
| 4 | bridge 注入时序问题 | 等待轮询 | 治标不治本 |
| 5 | 无法正确检测原生模式 | `isNativeApp()` 动态检测 | DOMContentLoaded 时 bridge 可能还未注入 |
| 6 | 无法打包签名分发 | N/A | pywebview 缺乏完善的 .app 打包链 |
| 7 | WKWebView 性能开销 | N/A | Python↔JS bridge 通信有不可消除的延迟 |
| 8 | WKWebView 缓存行为 | 重启应用 | 用户改了前端代码需要重启才生效 |

---

## 七、后端架构优势（迁移可复用）

FastAPI 后端**完全独立于 pywebview**，可以直接作为 Swift 原生客户端的后端：

```
uvicorn app_api:app --host 127.0.0.1 --port 8000
```

| 层 | 文件 | pywebview 依赖 |
|---|------|---------------|
| FastAPI 路由 | routers/*.py | **零** |
| 核心引擎 | sensevoice_core.py | **零** |
| AI 模块 | sensevoice_ai.py | **零** |
| 后台任务 | sensevoice_background.py | **零** |
| 数据库 | sensevoice_db.py | **零** |
| 状态管理 | services/*.py | **零** |

**需要替换的只有**：
- `main_app.py` (pywebview 窗口创建) → Swift AppDelegate
- `native_audio.py` (Python AVPlayer) → Swift AVPlayer
- `native_recording.py` (Python AVAudioEngine) → Swift AVAudioEngine
- 前端 13 个 `window.pywebview.api.*` 调用 → `window.webkit.messageHandlers.*`

---

## 八、Swift 原生客户端迁移要点

### 必须保留的功能
1. 实时录音 + 实时转写（原生 AVAudioEngine 采集 → ASR）
2. 文件上传转录（后台 VAD + ASR + 说话人分离 + LLM 优化）
3. 多模型选择 + 健康检查
4. AI 纪要（分段生成）
5. 说话人分离
6. 补转录
7. 导出四种格式
8. 搜索 + 历史管理

### 可以改进的
1. 搜索改为全文搜索（包含 plain_text）
2. `_retranscribing` 加锁保护
3. 导出时检测实际文件格式（wav/mp3）
4. SQLite 启用外键约束 `PRAGMA foreign_keys = ON`
5. API Key 加密存储（macOS Keychain）
6. LLM 批处理三种录音模式行为统一

### Swift 原生解决的问题
1. AVAudioEngine 直接获权，Info.plist 声明后一次性授权 → 无麦克风弹窗
2. NSSavePanel 原生对话框 → 导出体验完美
3. WKScriptMessageHandler 在 WKWebView 创建时注册 → 零时序问题
4. Xcode → .app bundle → DMG/公证/签名 → 直接分发
5. Swift ↔ WKWebView 通信是 WebKit 内核级优化 → 更好性能

---

## 九、当前数据库 Schema

### transcription_history
```sql
CREATE TABLE transcription_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    original_filename TEXT,
    audio_path TEXT,
    file_hash TEXT,
    duration REAL,
    model_size TEXT,
    language TEXT,
    timestamp_text TEXT,
    plain_text TEXT,
    detected_lang TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### ai_summaries
```sql
CREATE TABLE ai_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    history_id INTEGER,
    prompt TEXT,
    summary TEXT,
    model_name TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (history_id) REFERENCES transcription_history(id) ON DELETE CASCADE
);
```

---

## 十、当前 AI 配置

| 配置项 | 值 |
|--------|-----|
| 活跃模型 | `remote_deepseek-chat` (DeepSeek) |
| 已验证模型 | 3 个：💻 qwen3.5-4b-mlx (本地)、☁️ S3-Qwen (远程)、☁️ deepseek-chat (远程) |
| Prompt | 高度定制的"会议语境重建与记录整理专家"长 Prompt |

---

*本文档由代码分析自动生成，作为 gstack `/office-hours` brainstorm 和 `/autoplan` 的输入。*
