import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var services: some View {
        let readiness = readiness
        let item: (Int) -> SettingsReadiness.Item = { role in
            switch ServiceRole(rawValue: role) ?? .speechRecognition {
            case .speechRecognition: return .speech
            case .answerTriggers: return .triggers
            case .knowledgeIndexing: return .knowledge
            case .analysisAndAnswers: return .answers
            }
        }
        return VStack(alignment: .leading, spacing: 16) {
            LCSegmented(title: t("Service role"), selection: $serviceRole, items: [
                (ServiceRole.speechRecognition.rawValue, b("Speech recognition", "语音识别")),
                (ServiceRole.answerTriggers.rawValue, b("Answer triggers", "实时回答触发")),
                (ServiceRole.knowledgeIndexing.rawValue, b("Knowledge indexing", "知识库索引")),
                (ServiceRole.analysisAndAnswers.rawValue, b("Analysis & answers", "分析与回答"))
            ], dot: { readiness[item($0)].tone }).accessibilityIdentifier("service-role")
            switch ServiceRole(rawValue: serviceRole) ?? .speechRecognition {
            case .answerTriggers: automaticTriggerSettings
            case .knowledgeIndexing: embeddingService
            case .analysisAndAnswers: analysisService
            case .speechRecognition: liveService
            }
        }.padding(.bottom, 24)
    }
    var liveService: some View {
        VStack(alignment: .leading, spacing: 14) {
            LCSettingsCard(b("Speech recognition engine", "语音识别引擎"), subtitle: b("Turns both sides of the conversation into text.", "把对话双方的语音转成文字。"),
                           systemImage: "waveform", status: lockedStatus) {
                LCSettingsRow(b("Engine", "当前引擎")) {
                    Picker(b("Engine", "当前引擎"), selection: $coordinator.settings.listeningService) {
                        Text(b("Zipformer · Local Chinese + English · Terminology", "Zipformer · 本地中英双语 · 术语增强")).tag(ListeningService.zipformer)
                        Text(b("Paraformer · Local Chinese + English", "Paraformer · 本地中英双语")).tag(ListeningService.paraformer)
                        Text(b("Apple local speech recognition", "Apple 本机语音识别")).tag(ListeningService.apple)
                        Text("OpenAI · GPT-Live-1").tag(ListeningService.openAI)
                    }.labelsHidden().fixedSize().disabled(locked).accessibilityIdentifier("listening-provider")
                }
                Divider()
                LCSettingsRow(b("Recognition language", "识别语言")) {
                    if coordinator.settings.listeningService == .apple {
                        Picker(b("Recognition language", "识别语言"), selection: $coordinator.settings.appleSpeechLanguage) {
                            Text(b("Mandarin Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                            Text(b("English (US)", "英语（美国）")).tag(AppleSpeechLanguage.english)
                        }.labelsHidden().fixedSize().disabled(locked || coordinator.appleSpeech.busy).accessibilityIdentifier("apple-speech-language")
                    } else {
                        LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage,
                                                 interfaceLanguage: coordinator.settings.language, compact: true).labelsHidden().fixedSize().disabled(locked)
                    }
                }
                Divider()
                Text(liveEngineSummary).font(.callout).foregroundStyle(.secondary)
                if coordinator.settings.listeningService == .openAI {
                    Text(ServiceGuide.livePrice(coordinator.settings.liveModel, language: coordinator.settings.language)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(liveEngineTags, id: \.self) { label in
                        LCPill(text: label)
                    }
                }
                if coordinator.settings.listeningService == .apple {
                    Text(b("Only the selected language is recognized. Use Zipformer for mixed Chinese and English.", "仅识别所选语言，不自动切换中英文；混合语言建议使用 Zipformer。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if coordinator.settings.listeningService == .openAI {
                    Text(b("Language options guide recognition without restricting the languages recognized.", "语言选项仅影响识别偏好，不限制实际识别语言。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(b("Automatically detects complete questions and triggers answer generation.", "自动识别完整提问，触发分析模型生成回答。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LCSettingsCard(b("Model connection and download management", "模型连接与下载管理"),
                           systemImage: coordinator.settings.listeningService == .openAI ? "network" : "arrow.down.circle", status: speechModelStatus) {
                if coordinator.settings.listeningService == .apple {
                    VStack(alignment: .leading, spacing: 12) {
                        LCSettingsRow(b("Apple speech recognition model", "Apple 语音识别模型"),
                                      detail: b("Apple · Single language · ", "Apple · 单语言 · ") + appleSpeechStatusText) {
                            EmptyView()
                        }
                        HStack(spacing: 8) {
                            Button(b("Download / Retry", "下载/重试")) { coordinator.appleSpeech.install(coordinator.settings.appleSpeechLanguage) }
                                .disabled(locked || coordinator.appleSpeech.busy || coordinator.appleSpeech.installed || !coordinator.appleSpeech.available)
                            Button(b("Check again", "重新检测")) { Task { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) } }
                                .disabled(coordinator.appleSpeech.busy)
                            if coordinator.appleSpeech.busy {
                                ProgressView().controlSize(.small)
                                Button(t("Cancel")) { coordinator.appleSpeech.cancel() }
                            }
                            Spacer()
                        }
                    }
                } else if let kind = coordinator.settings.listeningService.localModel {
                    LocalModelCard(compact: true, manager: coordinator.localModels, kind: kind, language: coordinator.settings.language,
                                   locked: locked || coordinator.isIndexing || coordinator.answerIsRunning,
                                   remove: { coordinator.removeLocalModel(kind) })
                } else {
                    CredentialEditor(coordinator: coordinator, analysis: false, liveLayout: true)
                    DisclosureGroup(b("Advanced model settings", "高级模型设置")) {
                        modelField("Live model", value: $coordinator.settings.liveModel).disabled(locked).padding(.top, 8)
                    }
                }
            }
            if coordinator.settings.listeningService == .zipformer {
                professionalTermsSection
            }
        }.task(id: coordinator.settings.appleSpeechLanguage) {
            if coordinator.settings.listeningService == .apple { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) }
        }.task(id: coordinator.settings.listeningService) {
            if coordinator.settings.listeningService == .apple { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) }
        }
    }
    var professionalTermsSection: some View {
        LCSettingsCard(b("Professional terminology", "专业术语识别"), systemImage: "character.book.closed", status: ("Beta", .accent)) {
            LCSettingsRow(b("Enable terminology enhancement", "启用术语增强")) {
                LCSwitch(title: b("Enable terminology enhancement", "启用术语增强"), isOn: Binding(
                    get: { coordinator.settings.listeningService == .zipformer && coordinator.settings.professionalTermsEnabled },
                    set: { coordinator.settings.professionalTermsEnabled = $0 }))
                    .disabled(!ProfessionalTerms.supportsNativeEnhancement(coordinator.settings.listeningService))
            }
            if coordinator.settings.listeningService == .zipformer {
                Text(b("Add technical terms to guide recognition. Edits apply at the next speech segment; results may vary.", "添加专业词汇帮助识别；修改从下一段语音起生效，识别效果因发音而异。"))
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.localModels.installed.contains(.terminologySpeech), coordinator.settings.professionalTermsEnabled {
                    Text("\(coordinator.activeProfessionalTerms.count) " + b("active terms", "条可用于识别"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(b("Select Zipformer to use terminology enhancement. Your vocabulary is saved locally.", "选择 Zipformer 引擎即可使用术语增强。词表会保存在本机。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if coordinator.settings.professionalTermsEnabled {
                HStack {
                    Text(b("Custom terms", "自定义热词")).font(.callout)
                    Spacer()
                    Text("\(coordinator.settings.professionalTerms.count) " + b("saved terms", "个词条 · 已保存"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $professionalTermsDraft)
                    .font(.body).frame(height: 120).scrollContentBackground(.hidden)
                    .padding(8).lcWell()
                    .accessibilityLabel(b("One professional term per line", "每行一个专业术语"))
                Text(b("One term per line. Chinese, English, mixed-language terms and phrases with spaces are supported. Blank and duplicate entries are removed when saved.", "每行一个术语，支持中文、英文、中英混合及含空格的词组。保存时自动忽略空行和重复项。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(b("Up to 100 saved entries are considered, each up to 100 characters. Punctuation separates words; unsupported characters are skipped.", "为保持实时性，最多处理前 100 条，每条不超过 100 字。标点按词间空格处理；含模型不支持字符的词条不应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(b("Restore examples", "恢复示例")) { professionalTermsDraft = ProfessionalTerms.examples.joined(separator: "\n") }
                    Button(b("Copy terms", "复制热词列表")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinator.settings.professionalTerms.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }
        .onAppear { professionalTermsDraft = coordinator.settings.professionalTerms.joined(separator: "\n") }
        .onChange(of: professionalTermsDraft) { _, value in coordinator.settings.professionalTerms = ProfessionalTerms.clean(value) }
    }
    func liveSection<Content: View>(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        LCSettingsCard(title, systemImage: systemImage, content: content)
    }
    /// Shown in a card header while listening locks its choices.
    var lockedStatus: (text: String, tone: LC.Tone)? {
        locked ? (b("Stop listening to change", "停止监听后可更改"), .neutral) : nil
    }
    var appleSpeechStatusText: String {
        let message = coordinator.appleSpeech.message
        if !message.isEmpty { return L10n.text(message, language: coordinator.settings.language) }
        return coordinator.appleSpeech.installed ? b("Installed · offline ready", "已安装 · 可离线使用") : b("Not downloaded", "未下载")
    }
    /// The speech model's state, from the same readiness the Overview shows.
    var speechModelStatus: (text: String, tone: LC.Tone)? {
        let entry = readiness[.speech]
        // Local models show their own, more detailed state (self-check, queue, failure) inside the card.
        guard coordinator.settings.listeningService.localModel == nil else { return nil }
        if coordinator.settings.listeningService == .apple && coordinator.appleSpeech.busy { return (b("Downloading…", "下载中…"), .accent) }
        switch entry.state {
        case .ready: return (coordinator.settings.listeningService == .openAI ? b("Key saved", "密钥已保存") : b("Ready", "已就绪"), .success)
        case .needsSetup: return (coordinator.settings.listeningService == .openAI ? b("No key", "未保存密钥") : b("Not downloaded", "未下载"), .warning)
        case .inactive: return nil
        }
    }
    var liveEngineSummary: String {
        switch coordinator.settings.listeningService {
        case .apple: return b("Built-in macOS recognition, transcribing Chinese or English offline.", "使用 macOS 内置识别能力，离线实时转写中文或英文。")
        case .zipformer: return b("Local Chinese/English streaming with native terminology enhancement, no API fees.", "本地中英双语实时识别，支持原生术语增强，无 API 费用。")
        case .paraformer: return b("Transcribes mixed Chinese and English locally, without API fees.", "支持中英文混合语音转写，本地离线运行，无需 API 费用。")
        case .openAI: return b("Cloud transcription with intelligent detection of complete questions.", "云端实时转写，并智能判断提问是否完整。")
        }
    }
    var liveEngineTags: [String] {
        switch coordinator.settings.listeningService {
        case .apple: return [b("Local", "本地"), b("Single language", "单语识别"), b("No API fees", "无 API 费用")]
        case .zipformer: return [b("Local", "本地"), b("Chinese + English", "中英混合"), b("Terminology", "术语增强"), b("No API fees", "无 API 费用")]
        case .paraformer: return [b("Local", "本地"), b("Chinese + English", "中英混合"), b("No API fees", "无 API 费用")]
        case .openAI: return [b("Cloud", "云端"), b("Multilingual", "多语言"), b("Usage-based", "按量计费")]
        }
    }
    var embeddingService: some View {
        VStack(alignment: .leading, spacing: 18) {
            LCSettingsCard(b("Knowledge indexing", "知识库索引"),
                           subtitle: b("Index imported documents and retrieve relevant passages before an answer is generated.", "为导入的文档建立索引，在生成回答前找出相关片段。"),
                           systemImage: "doc.text.magnifyingglass", tone: .success, status: readiness[.knowledge].badge(coordinator.settings.language)) {
                LCSettingsRow(b("Knowledge index model", "知识库索引模型"),
                              detail: b("Converts documents and questions to vectors to find related passages. This model does not generate answers.", "将文档和问题转换为向量，以便检索相关片段。此模型不负责生成回答。")) {
                    Picker(b("Knowledge index model", "知识库索引模型"), selection: $coordinator.settings.embeddingService) {
                        ForEach(EmbeddingService.allCases) { service in
                            Text(service == .local ? b("\(LocalModelKind.embeddingName) (local, recommended)", "\(LocalModelKind.embeddingName)（本地，推荐）") : b("OpenAI index model (remote)", "OpenAI 索引模型（远程）")).tag(service)
                        }
                    }.labelsHidden().fixedSize().disabled(coordinator.isIndexing || coordinator.answerIsRunning).accessibilityIdentifier("embedding-provider")
                }
                if let reason = readiness[.knowledge].reason, readiness[.knowledge].needsSetup, !coordinator.knowledgeNeedsReindex {
                    Label(reason, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(LC.warning)
                }
                if coordinator.settings.embeddingService == .openAI {
                    Text(b("Billed per token · knowledge indexing only", "按 token 计费 · 仅用于知识库索引")).font(.caption)
                    modelField("Embedding model", value: $coordinator.settings.embeddingModel).disabled(coordinator.isIndexing)
                    Text(ServiceGuide.embeddingPrice(coordinator.settings.embeddingModel, language: coordinator.settings.language, compact: true))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(b("Recommended for most users · runs locally · free · no OpenAI key required", "推荐多数用户使用 · 本地运行 · 免费 · 无需 OpenAI Key")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.settings.embeddingService == .local {
                LocalModelCard(manager: coordinator.localModels, kind: .embedding, language: coordinator.settings.language, locked: locked || coordinator.isIndexing || coordinator.answerIsRunning, remove: { coordinator.removeLocalModel(.embedding) })
            } else {
                Text(t("Extracted document text and retrieval queries are sent to OpenAI Embeddings using the shared OpenAI credential.")).font(.callout).foregroundStyle(.secondary)
                if !coordinator.hasAPIKey {
                    Text(b("No OpenAI key configured for remote indexing. Use local \(LocalModelKind.embeddingName) to index without a key. Your answer model configuration is separate.", "远程索引尚未配置 OpenAI Key。可切回本地 \(LocalModelKind.embeddingName) 免密钥建立索引。回答模型在「分析与回答」中单独配置。")).font(.callout)
                } else if case .failed = coordinator.embeddingVerification {
                    Text(b("Remote indexing failed. You can switch to local \(LocalModelKind.embeddingName). This check only tests knowledge indexing.", "远程索引连接失败，可切回本地 \(LocalModelKind.embeddingName)。本次检查仅针对知识库索引，不代表回答服务连接失败。")).font(.callout)
                }
                CredentialEditor(coordinator: coordinator, analysis: false, embeddingLayout: true)
            }
            if coordinator.knowledgeNeedsReindex {
                HStack(spacing: 12) {
                    Label(b("The indexing model has changed. Rebuild existing documents' indexes to use semantic retrieval with this model.", "索引模型已切换，请重新建立已有文档的索引，才能使用当前模型进行语义检索。"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(LC.warning)
                    Spacer()
                    Button(b("Rebuild indexes", "重新建立索引")) { coordinator.reindexAll() }
                        .disabled(!knowledgeConfigured || coordinator.isIndexing)
                }.lcCallout(.warning)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    if coordinator.settings.embeddingService == .local { localCost }
                    Text(t("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.")).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { page = .knowledge } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "books.vertical")
                        Text(t("Open knowledge library"))
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered).tint(LC.accent).fixedSize()
                .accessibilityIdentifier("open-knowledge-library")
            }
        }
        .task(id: coordinator.settings.selectedEmbeddingIdentity) {
            if coordinator.settings.embeddingService == .openAI {
                let model = coordinator.settings.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else { return }
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
                guard !Task.isCancelled else { return }
            }
            await coordinator.verifyEmbeddingIfNeeded()
        }
        .onChange(of: coordinator.hasAPIKey) { _, available in
            if available { Task { await coordinator.verifyEmbeddingIfNeeded() } }
        }
    }
    var analysisService: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingAnswerConfiguration(coordinator: coordinator, settingsStyle: true)
            if (try? coordinator.settings.analysisCredentialReference()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: coordinator.settings.reasoningService != .sharedOpenAI, analysisLayout: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            }
            LCSettingsCard(b("Answer style", "回答风格"), systemImage: "text.quote", tone: .pink) {
                    answerTranslationSetting
                    Divider()
                    Text(b("Additional answer instructions", "个性化额外提示词"))
                    TextEditor(text: Binding(get: { answerInstructionsDraft }, set: { answerInstructionsDraft = String($0.prefix(4000)) }))
                        .font(.body).frame(height: 100).scrollContentBackground(.hidden).padding(6).lcWell()
                        .accessibilityLabel(b("Additional answer instructions", "个性化额外提示词"))
                        .accessibilityIdentifier("additional-answer-instructions")
                    HStack {
                        Text(b("Example: Use short sentences and explain technical terms. Sent to your analysis service with each request.", "例如：用短句回答，并解释专业术语。每次请求会随问题发送给分析服务。"))
                        Spacer()
                        Text("\(answerInstructionsDraft.count)/4000").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(answerInstructionsDraft == coordinator.settings.additionalAnswerInstructions
                             ? b("Saved · applies to new answers", "已保存 · 对新回答生效")
                             : b("Unsaved changes", "有未保存的修改"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(b("Save", "保存")) {
                            coordinator.settings.additionalAnswerInstructions = answerInstructionsDraft
                        }
                        .disabled(answerInstructionsDraft == coordinator.settings.additionalAnswerInstructions)
                        .accessibilityIdentifier("save-answer-instructions")
                    }
                    Text(b("Your instructions take priority over default answer style, including translation lines. Factual accuracy still applies.", "自定义要求优先于默认回答风格和译文格式，但不会改变事实准确性要求。"))
                        .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    /// Translation lines after each answer sentence; languages are picked in order, up to three.
    private var answerTranslationSetting: some View {
        let title = b("Sentence translations", "逐句附译文")
        let enabled = Binding(get: { coordinator.settings.answerTranslationEnabled }, set: { on in
            if on && coordinator.settings.answerTranslationLanguages.isEmpty {
                coordinator.settings.answerTranslationLanguages = TranslationLanguage.defaults(for: coordinator.settings.language)
            }
            coordinator.settings.answerTranslationEnabled = on
        })
        let chosen = coordinator.settings.effectiveTranslationLanguages
        return VStack(alignment: .leading, spacing: 12) {
            LCSettingsRow(title, detail: b("Each answer sentence is followed by its translation. Applies to manual and automatic answers.",
                                           "每句回答后紧接对应译文。对手动和自动回答生效。")) {
                LCSwitch(title: title, isOn: enabled).accessibilityIdentifier("answer-translations")
            }
            if coordinator.settings.answerTranslationEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    LCFlowLayout(spacing: 8) {
                        ForEach(TranslationLanguage.allCases) { language in
                            translationChip(language, order: chosen.firstIndex(of: language), chosen: chosen)
                        }
                    }
                    Text(b("Pick up to \(TranslationLanguage.maximum); translations follow in the order picked. Sentences already in a picked language are not translated again.",
                           "最多选 \(TranslationLanguage.maximum) 种，译文按选择顺序排列；与原句语言相同的不再重复翻译。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("answer-translation-languages")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .lcAnimation(LC.Motion.standard, value: coordinator.settings.answerTranslationEnabled)
    }
    private func translationChip(_ language: TranslationLanguage, order: Int?, chosen: [TranslationLanguage]) -> some View {
        let selected = order != nil
        let full = chosen.count >= TranslationLanguage.maximum
        return Button {
            var languages = chosen
            if let order {
                guard languages.count > 1 else { return }   // keep at least one; turn the switch off instead
                languages.remove(at: order)
            } else if !full {
                languages.append(language)
            }
            coordinator.settings.answerTranslationLanguages = languages
        } label: {
            HStack(spacing: 5) {
                if let order {
                    Text("\(order + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                        .frame(width: 15, height: 15).background(Color.white.opacity(0.25), in: Circle())
                }
                Text(language.nativeName).font(.callout.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(selected ? LC.accent : LC.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!selected && full)
        .opacity(!selected && full ? 0.45 : 1)
        .accessibilityLabel(language.nativeName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("translation-" + language.rawValue)
    }
    var customService: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    modelField("API Base URL", value: $baseURL, prompt: "https://your-provider.example/v1")
                    modelField("API path", value: $apiPath, prompt: "chat/completions")
                    modelField("Reasoning model", value: $customModel)
                    Text(t("Use an HTTPS service supporting streamed Chat Completions. The base URL and path are joined; include /v1 only once.")).font(.caption).foregroundStyle(.secondary)
                    Button(t("Save connection")) { saveCustomConnection() }
                    if !connectionMessage.isEmpty { Text(t(connectionMessage)).font(.caption).foregroundStyle(.secondary) }
                }.padding(10)
            } label: { Text(t("Connection")) }
            if (try? coordinator.settings.compatibleEndpoint()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: true, analysisLayout: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            } else {
                Text(t("Save the service address before configuring its key.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func loadCustomDraft() {
        baseURL = coordinator.settings.compatibleBaseURL; apiPath = coordinator.settings.compatiblePath; customModel = coordinator.settings.compatibleModel
    }
    func saveCustomConnection() {
        do {
            _ = try ServiceEndpoint.make(baseURL: baseURL, path: apiPath)
            guard !customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
            var settings = coordinator.settings
            settings.compatibleBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.compatiblePath = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.compatibleModel = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            coordinator.settings = settings
            connectionMessage = "Connection saved. Credentials are scoped to this endpoint."
        } catch { connectionMessage = error.localizedDescription }
    }
    var localCost: some View {
        Text(b("Local/free means no API usage fee. The first model download needs a network connection and disk space.", "本地／免费指无 API 调用费。首次模型下载需要联网与磁盘空间。")).font(.caption).foregroundStyle(.secondary)
    }
    func priceNote(_ message: String, url: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(b("Usage & price", "用量与价格"), systemImage: "creditcard").font(.headline)
            Text(message).font(.callout).textSelection(.enabled)
            if let url, let destination = URL(string: url) {
                HStack {
                    Text(b("Reference checked ", "参考信息核对于 ") + ServiceGuide.checked).font(.caption)
                    Link(b("Official pricing", "官方价格"), destination: destination).font(.caption)
                }.foregroundStyle(.secondary)
                Text(b("Published list prices are a reference, not a bill. Provider updates, taxes and account discounts may change the amount.", "公布价格供参考，不是账单估算；厂商调价、税费和账户优惠可能影响实际费用。")).font(.caption2).foregroundStyle(.secondary)
            }
        }.lcCallout(.accent)
    }
    func fontSizeControl(_ title: String, value: Binding<Double>, identifier: String, preview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: value, in: OverlayTypography.range, step: 1).labelsHidden()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
            }
            Slider(value: value, in: OverlayTypography.range, step: 1)
                .accessibilityLabel(title).accessibilityIdentifier(identifier + "-slider")
            Text(preview).font(.system(size: value.wrappedValue)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    func modelField(_ title: String, value: Binding<String>, prompt: String? = nil) -> some View {
        HStack {
            Text(t(title)).frame(width: 120, alignment: .leading)
            TextField(t(title), text: value, prompt: Text(prompt ?? t(title))).textFieldStyle(.roundedBorder)
        }
    }
    var knowledgeConfigured: Bool {
        coordinator.settings.embeddingService == .local
            ? localModels.embeddingVerification.isReady
            : coordinator.hasAPIKey && coordinator.embeddingVerification.isReady
    }
}
