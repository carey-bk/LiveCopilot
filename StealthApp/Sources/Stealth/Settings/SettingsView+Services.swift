import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var services: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(t("Service role"), selection: $serviceRole) {
                Text(b("Speech recognition", "语音识别")).tag(ServiceRole.speechRecognition.rawValue)
                Text(b("Answer triggers", "实时回答触发")).tag(ServiceRole.answerTriggers.rawValue)
                Text(b("Knowledge indexing", "知识库索引")).tag(ServiceRole.knowledgeIndexing.rawValue)
                Text(b("Analysis & answers", "分析与回答")).tag(ServiceRole.analysisAndAnswers.rawValue)
            }.pickerStyle(.segmented).accessibilityIdentifier("service-role")
            switch ServiceRole(rawValue: serviceRole) ?? .speechRecognition {
            case .answerTriggers: automaticTriggerSettings
            case .knowledgeIndexing: embeddingService
            case .analysisAndAnswers: analysisService
            case .speechRecognition: liveService
            }
        }.padding(.bottom, 4)
    }
    var liveService: some View {
        VStack(alignment: .leading, spacing: 14) {
            liveSection(b("Speech recognition engine", "语音识别引擎")) {
                HStack(spacing: 20) {
                    Picker(b("Engine", "当前引擎"), selection: $coordinator.settings.listeningService) {
                        Text(b("Zipformer · Local Chinese + English · Terminology", "Zipformer · 本地中英双语 · 术语增强")).tag(ListeningService.zipformer)
                        Text(b("Paraformer · Local Chinese + English", "Paraformer · 本地中英双语")).tag(ListeningService.paraformer)
                        Text(b("Apple local speech recognition", "Apple 本机语音识别")).tag(ListeningService.apple)
                        Text("OpenAI · GPT-Live-1").tag(ListeningService.openAI)
                    }.disabled(locked).accessibilityIdentifier("listening-provider")
                    if coordinator.settings.listeningService == .apple {
                        Picker(b("Recognition language", "识别语言"), selection: $coordinator.settings.appleSpeechLanguage) {
                            Text(b("Mandarin Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                            Text(b("English (US)", "英语（美国）")).tag(AppleSpeechLanguage.english)
                        }.disabled(locked || coordinator.appleSpeech.busy).accessibilityIdentifier("apple-speech-language")
                    } else {
                        LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage,
                                                 interfaceLanguage: coordinator.settings.language, compact: true).disabled(locked)
                    }
                }
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
            liveSection(b("Model connection and download management", "模型连接与下载管理")) {
                if coordinator.settings.listeningService == .apple {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(b("Apple speech recognition model", "Apple 语音识别模型")).font(.headline)
                                Text(b("Apple · Single language", "Apple · 单语言")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(L10n.text(coordinator.appleSpeech.message, language: coordinator.settings.language),
                                  systemImage: coordinator.appleSpeech.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.caption).foregroundStyle(coordinator.appleSpeech.installed ? LC.success : Color.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(b("Download / Retry", "下载/重试")) { coordinator.appleSpeech.install(coordinator.settings.appleSpeechLanguage) }
                                .disabled(locked || coordinator.appleSpeech.busy || coordinator.appleSpeech.installed || !coordinator.appleSpeech.available)
                            if coordinator.appleSpeech.busy {
                                ProgressView().controlSize(.small)
                                Button(t("Cancel")) { coordinator.appleSpeech.cancel() }
                            }
                            Spacer()
                            Button(b("Check again", "重新检测")) { Task { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) } }
                                .disabled(coordinator.appleSpeech.busy)
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
        liveSection(b("Professional terminology", "专业术语识别"), beta: true) {
            Toggle(b("Enable terminology enhancement", "启用术语增强"), isOn: Binding(
                get: { coordinator.settings.listeningService == .zipformer && coordinator.settings.professionalTermsEnabled },
                set: { coordinator.settings.professionalTermsEnabled = $0 }))
                .disabled(!ProfessionalTerms.supportsNativeEnhancement(coordinator.settings.listeningService))
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
    func liveSection<Content: View>(_ title: String, beta: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if beta {
                    Capsule().fill(LC.accent)
                        .overlay {
                            Text("Beta").font(.custom(AppBrandTitle.fontName, size: 11))
                                .foregroundStyle(Color.white)
                        }
                        .compositingGroup()
                        .frame(width: 40, height: 18)
                        .accessibilityLabel("Beta")
                }
            }
            content()
        }.lcCard()
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
            liveSection(b("Knowledge indexing", "知识库索引")) {
                Text(b("Index imported documents and retrieve relevant passages before an answer is generated.", "为导入的文档建立索引，在生成回答前找出相关片段。"))
                Button(b("Configure the answer model in Analysis & answers", "前往「分析与回答」配置回答模型")) { serviceRole = ServiceRole.analysisAndAnswers.rawValue }
                    .buttonStyle(.link)
                Divider()
                Picker(b("Knowledge index model", "知识库索引模型"), selection: $coordinator.settings.embeddingService) {
                    ForEach(EmbeddingService.allCases) { service in
                        Text(service == .local ? b("\(LocalModelKind.embeddingName) (local, recommended)", "\(LocalModelKind.embeddingName)（本地，推荐）") : b("OpenAI index model (remote)", "OpenAI 索引模型（远程）")).tag(service)
                    }
                }.disabled(coordinator.isIndexing || coordinator.answerIsRunning).accessibilityIdentifier("embedding-provider")
                Text(b("Converts documents and questions to vectors to find related passages. This model does not generate answers.", "将文档和问题转换为向量，以便检索相关片段。此模型不负责生成回答。"))
                    .font(.callout).foregroundStyle(.secondary)
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
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(b("Rebuild indexes", "重新建立索引")) { coordinator.reindexAll() }
                        .disabled(!knowledgeConfigured || coordinator.isIndexing)
                }
            }
            if coordinator.settings.embeddingService == .local { localCost }
            Text(t("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.")).font(.caption).foregroundStyle(.secondary)
            Button(t("Open knowledge library")) { page = .knowledge }
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
            OnboardingAnswerConfiguration(coordinator: coordinator)
            if (try? coordinator.settings.analysisCredentialReference()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: coordinator.settings.reasoningService != .sharedOpenAI, analysisLayout: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(b("Chinese / English sentence pairs", "中英逐句对照"), isOn: $coordinator.settings.bilingualAnswers)
                        .accessibilityIdentifier("bilingual-answers")
                    Text(b("Each Chinese sentence is followed by its English equivalent. Applies to manual and automatic answers and overrides single-language output.", "每句中文后紧接对应英文。对手动和自动回答生效，优先于单语设置。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(b("Additional answer instructions", "个性化额外提示词")).font(.headline)
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
                    Text(b("Your instructions take priority over default answer style, including bilingual formatting. Factual accuracy still applies.", "自定义要求优先于默认回答风格和中英对照格式，但不会改变事实准确性要求。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Text(b("Answer style", "回答风格")) }
        }
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
