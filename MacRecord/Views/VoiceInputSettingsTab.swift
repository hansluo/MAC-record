import SwiftUI

/// 语音输入设置 Tab
struct VoiceInputSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPromptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("语音输入")
                    .font(.title2.weight(.semibold))

                // 开关
                GroupBox {
                    Toggle(isOn: Binding(
                        get: { appState.voiceInputService.configStore.isEnabled },
                        set: { newValue in
                            appState.voiceInputService.configStore.isEnabled = newValue
                            saveAndReload()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用语音输入")
                                .font(.headline)
                            Text("长按热键开始说话，松开后自动识别并输入到当前文本框")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 热键设置
                GroupBox("热键") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("触发键", selection: Binding(
                            get: { appState.voiceInputService.configStore.hotkeyType },
                            set: { newValue in
                                appState.voiceInputService.configStore.hotkeyType = newValue
                                saveAndReload()
                            }
                        )) {
                            ForEach(HotkeyType.allCases) { hk in
                                Text(hk.displayName).tag(hk)
                            }
                        }
                        .frame(maxWidth: 300)

                        HStack {
                            Text("长按阈值")
                            Slider(
                                value: Binding(
                                    get: { Double(appState.voiceInputService.configStore.longPressThresholdMs) },
                                    set: { newValue in
                                        appState.voiceInputService.configStore.longPressThresholdMs = Int(newValue)
                                        saveAndReload()
                                    }
                                ),
                                in: 200...800,
                                step: 50
                            )
                            .frame(maxWidth: 200)
                            Text("\(appState.voiceInputService.configStore.longPressThresholdMs)ms")
                                .font(.caption.monospacedDigit())
                                .frame(width: 50)
                        }

                        Text("低于此时间松开视为正常快捷键，超过此时间触发语音输入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // LLM 纠错设置
                GroupBox("智能纠错") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { appState.voiceInputService.configStore.llmCorrectionEnabled },
                            set: { newValue in
                                appState.voiceInputService.configStore.llmCorrectionEnabled = newValue
                                saveAndReload()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("LLM 纠错")
                                    .font(.subheadline.weight(.medium))
                                Text("使用 AI 模型纠正同音字、添加标点（需要配置 AI 模型）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if appState.voiceInputService.configStore.llmCorrectionEnabled {
                            HStack {
                                Text("短句阈值")
                                Stepper(
                                    "\(appState.voiceInputService.configStore.shortThreshold) 字",
                                    value: Binding(
                                        get: { appState.voiceInputService.configStore.shortThreshold },
                                        set: { newValue in
                                            appState.voiceInputService.configStore.shortThreshold = newValue
                                            saveAndReload()
                                        }
                                    ),
                                    in: 5...30
                                )
                            }

                            Text("低于此字数的短句直接输出，不经过 LLM（减少延迟）")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            // 纠错模型选择
                            Picker("纠错模型", selection: Binding(
                                get: { appState.voiceInputService.configStore.voiceInputModelId },
                                set: { newValue in
                                    appState.voiceInputService.configStore.voiceInputModelId = newValue
                                    saveAndReload()
                                }
                            )) {
                                Text("跟随全局活跃模型").tag("")
                                ForEach(appState.llmConfigStore.models) { model in
                                    Text(model.label.isEmpty ? model.modelName : model.label).tag(model.id)
                                }
                            }
                            .frame(maxWidth: 350)

                            // 当前使用的模型状态
                            if let resolved = appState.voiceInputService.configStore.resolvedModel(from: appState.llmConfigStore) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                    Text("使用模型: \(resolved.label.isEmpty ? resolved.modelName : resolved.label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text("未配置 AI 模型，纠错功能不可用")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }

                            // 纠错 Prompt 编辑
                            DisclosureGroup("纠错 Prompt", isExpanded: $isPromptExpanded) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("留空使用内置默认 prompt（根据文本长度自动分档）")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $appState.llmConfigStore.asrOptimizePrompt)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(minHeight: 100)
                                        .border(Color(nsColor: .separatorColor))
                                    Button("保存") {
                                        appState.llmConfigStore.save()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(8)
                }

                // 辅助功能权限
                GroupBox("权限") {
                    HStack {
                        if AccessibilityHelper.isAccessibilityGranted {
                            Label("辅助功能权限已授权", systemImage: "checkmark.shield.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("需要辅助功能权限", systemImage: "lock.shield")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                                Text("语音输入需要此权限来检测热键和注入文字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("前往授权") {
                                    AccessibilityHelper.checkAndRequestAccessibility()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
    }

    private func saveAndReload() {
        appState.voiceInputService.configStore.save()
        appState.voiceInputService.reloadConfig()
    }
}
