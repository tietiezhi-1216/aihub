import SwiftUI
import AIHubCore

struct DictationView: View {
    @Bindable var state: AppState
    @State private var vocabulary = ""

    var body: some View {
        Form {
            Section("语音识别 (ASR)") {
                modelPicker(speech: true)
                    .disabled(state.locked)
                if state.speechOptions.isEmpty {
                    Button("添加语音模型") { state.page = .providers }
                }
                Picker("语言", selection: Binding(
                    get: { state.settings.language }, set: { state.setLanguage($0) }
                )) {
                    Text("自动识别").tag("")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    if state.provider(for: state.settings.speechSelection)?.effectiveProtocol != .xiaomi {
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                }
                .disabled(state.locked || usesAutomaticLanguage)

                DisclosureGroup("词汇提示") {
                    TextField("词汇", text: $vocabulary)
                        .onSubmit { saveVocabulary() }
                    Button("保存") { saveVocabulary() }
                        .disabled(vocabulary.count > 2000)
                }
                .disabled(state.locked || usesAutomaticLanguage || state.settings.speechSelection?.modelID.lowercased().hasSuffix("transcribe-diarize") == true)

                recordingControls
                if let url = state.audioURL, !state.recorder.isRecording {
                    LabeledContent("音频") {
                        Text(state.importedAudio != nil ? url.lastPathComponent : "本次录音.m4a")
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if state.isProcessing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(state.operationLabel)
                        Button("取消") { state.cancelOperation() }
                    }
                } else if state.isStartingRecording {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("等待麦克风授权…")
                    }
                }
            }

            Section("原始文字") {
                TextEditor(text: $state.transcript)
                    .frame(minHeight: 140)
                    .disabled(state.isProcessing)
                HStack {
                    Button("复制") { state.copy(state.transcript) }
                        .disabled(state.transcript.isEmpty)
                    if let original = state.lastTranscription, original != state.transcript {
                        Button("恢复原文") { state.transcript = original }
                            .disabled(state.locked)
                    }
                }
            }

            Section("文字处理 (LLM)") {
                modelPicker(speech: false).disabled(state.locked)
                if let group = state.chatGroup, group.hasThinking,
                   let provider = state.provider(for: state.settings.chatSelection), provider.channelType == .antigravity {
                    ModelThinkingPicker(group: group, thinking: Binding(
                        get: { state.activeVariant(in: group, provider: provider).thinking },
                        set: { state.chooseThinking($0, providerID: provider.id, groupID: group.id) }
                    ), labelsHidden: false).disabled(state.locked)
                }
                if let provider = state.provider(for: state.settings.chatSelection), let selection = state.settings.chatSelection,
                   !provider.channelType.isSubscription {
                    DisclosureGroup("思考与输出上限") {
                        APIReasoningControls(state: state, providerID: provider.id, modelID: selection.modelID)
                    }
                }
                Picker("方式", selection: $state.transformMode) {
                    ForEach(TransformMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.disabled(state.locked)
                DisclosureGroup("自定义指令") {
                    TextEditor(text: $state.customInstruction)
                        .frame(height: 80)
                        .disabled(state.locked)
                }
                Button(state.transformMode.title) { state.transform() }
                    .disabled(state.locked || state.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              state.settings.chatSelection == nil)
                if !state.transformedText.isEmpty {
                    TextEditor(text: $state.transformedText)
                        .frame(minHeight: 130)
                        .disabled(state.isProcessing)
                    Button("复制结果") { state.copy(state.transformedText) }
                    if let usage = state.lastTextUsage {
                        Text(usage.usage.summary + " · " + usage.costSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { vocabulary = state.settings.vocabulary }
        .alert("录音提示", isPresented: Binding(
            get: { state.recorder.error != nil },
            set: { if !$0 { state.recorder.error = nil } }
        )) {
            Button("好", role: .cancel) { state.recorder.error = nil }
        } message: {
            Text(state.recorder.error ?? "")
        }
    }

    private var recordingControls: some View {
        HStack {
            if state.recorder.isRecording {
                Button("停止录音") { state.stopRecording() }
            } else {
                Button(state.hasAudio ? "重新录音" : "开始录音") { state.startRecording() }
                    .disabled(state.locked)
                Button("导入音频…") { state.importAudio() }
                    .disabled(state.locked)
            }
            if state.hasAudio, !state.recorder.isRecording {
                Button("仅识别") { state.transcribe() }
                    .disabled(state.locked || state.settings.speechSelection == nil)
                Button("识别并润色") { state.transcribe(polish: true) }
                    .disabled(state.locked || state.settings.speechSelection == nil || state.settings.chatSelection == nil)
                    .help("先用 ASR 识别，再用已选 LLM 润色；识别原文不变。")
                Button("清除音频") { state.discardAudio() }
                    .disabled(state.locked)
            }
            if state.recorder.isRecording || (state.recorder.fileURL != nil && state.importedAudio == nil) {
                Spacer()
                Text(timeString).monospacedDigit()
            }
            if state.recorder.isRecording {
                ProgressView(value: state.recorder.level)
                    .frame(width: 70)
                    .accessibilityLabel("麦克风输入电平")
            }
        }
    }

    private func modelPicker(speech: Bool) -> some View {
        Picker(speech ? "ASR 模型" : "LLM 模型", selection: Binding<ModelSelection?>(
            get: { speech ? state.settings.speechSelection : state.settings.chatSelection },
            set: { if speech { state.chooseSpeech($0) } else { state.chooseChat($0) } }
        )) {
            Text("未选择").tag(nil as ModelSelection?)
            ForEach(speech ? state.speechOptions : state.chatOptions, id: \.self) { selection in
                Text(state.label(for: selection)).tag(Optional(selection))
            }
        }
    }

    private var usesAutomaticLanguage: Bool {
        state.provider(for: state.settings.speechSelection)?.usesSiliconFlowSpeech == true
    }

    private var timeString: String {
        let seconds = Int(state.recorder.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func saveVocabulary() {
        state.setVocabulary(vocabulary)
    }
}
