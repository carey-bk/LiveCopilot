import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @State private var page = SettingsPage.general
    @State private var analysis = false
    @State private var baseURL = ""
    @State private var apiPath = ""
    @State private var customModel = ""
    @State private var connectionMessage = ""
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; hotkeys = coordinator.hotkeys }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("LiveCopilot").font(.title2.weight(.semibold)).padding(.horizontal, 16).padding(.top, 22)
                VStack(spacing: 5) {
                    ForEach(SettingsPage.allCases) { item in
                        Button { page = item } label: {
                            Label(t(item.rawValue), systemImage: item.icon)
                                .font(.system(size: 14, weight: page == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .background(page == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-" + item.id)
                    }
                }.padding(.horizontal, 10)
                Spacer()
                Text(coordinator.isMock ? t("MOCK — no API calls") : AppInfo.display)
                    .font(.caption2).foregroundStyle(.secondary).padding(16)
            }.frame(width: 180).background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text(t(page.rawValue)).font(.system(size: 24, weight: .semibold))
                switch page {
                case .general: ScrollView { general }
                case .services: ScrollView { services }
                case .knowledge: knowledge
                case .shortcuts: shortcuts
                }
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 610, idealHeight: 680)
        .background(coordinator.settings.background == .white ? Color.white : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(coordinator.settings.background == .white ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .onAppear { loadCustomDraft() }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(t("Interface language"), selection: $coordinator.settings.language) {
                        Text(t("Follow system")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    }.accessibilityIdentifier("interface-language")
                    Text(t("Changes apply immediately. Answers follow the language of your question.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker(t("Window background"), selection: $coordinator.settings.background) {
                        Text(t("Translucent glass")).tag(AppBackground.glass)
                        Text(t("Solid white")).tag(AppBackground.white)
                    }.pickerStyle(.segmented).accessibilityIdentifier("window-background")
                    Text(t("Solid white keeps dark text readable over any wallpaper.")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Language & appearance"), systemImage: "textformat") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("Operating mode"), selection: $coordinator.settings.mode) {
                        ForEach(OperatingMode.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Picker(t("Scenario"), selection: $coordinator.settings.scenario) {
                        ForEach(ScenarioProfile.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    if locked { Text(t("Stop listening to change mode or scenario.")).font(.caption).foregroundStyle(.secondary) }
                    Toggle(t("Automatic suggestions for meaningful questions"), isOn: $coordinator.settings.automaticSuggestions)
                }.padding(10)
            } label: { Label(t("Conversation"), systemImage: "waveform") }
            VStack(alignment: .leading, spacing: 7) {
                Label(t("Capture exclusion"), systemImage: "eye.slash").font(.headline)
                Text(t("macOS is asked to exclude the overlay, settings and history from capture. This is why they can disappear in screenshots. Verify the result in your meeting app.")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 4)
    }
    private var services: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(t("Service role"), selection: $analysis) {
                Text(t("Live service")).tag(false)
                Text(t("Analysis service")).tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("service-role")
            if analysis { analysisService } else { liveService }
        }.padding(.bottom, 4)
    }
    private var liveService: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("OpenAI", systemImage: "waveform").font(.title3.bold())
            Text(t("Live conversation uses GPT-Live-1. Knowledge indexing and query embeddings also use this OpenAI credential.")).font(.callout).foregroundStyle(.secondary)
            CredentialEditor(coordinator: coordinator, analysis: false)
            SettingsSection {
                VStack(spacing: 14) {
                    modelField("Live model", value: $coordinator.settings.liveModel).disabled(locked)
                    modelField("Embedding model", value: $coordinator.settings.embeddingModel).disabled(coordinator.isIndexing)
                    Text(t("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Text(t("Models")) }
        }
    }
    private var analysisService: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(t("Provider"), selection: $coordinator.settings.reasoningService) {
                ForEach(ReasoningService.allCases) { Text(t($0.label)).tag($0) }
            }.accessibilityIdentifier("analysis-provider")
            Text(t("This service combines the question, conversation and retrieved evidence into an answer. Live audio stays with OpenAI.")).font(.callout).foregroundStyle(.secondary)
            if coordinator.settings.reasoningService == .sharedOpenAI {
                Label(t("Using the Live service credential."), systemImage: "link").font(.headline)
                CredentialStatus(coordinator: coordinator, analysis: false)
                Button(t("Manage Live service")) { analysis = false }
            } else if coordinator.settings.reasoningService != .compatible {
                CredentialEditor(coordinator: coordinator, analysis: true).id(coordinator.settings.reasoningService)
            }
            switch coordinator.settings.reasoningService {
            case .sharedOpenAI, .separateOpenAI:
                SettingsSection {
                    VStack(spacing: 14) {
                        modelField("Reasoning model", value: $coordinator.settings.reasoningModel)
                        Picker(t("Reasoning effort"), selection: $coordinator.settings.reasoningEffort) {
                            Text(t("Model default")).tag(""); Text(t("Low (faster)")).tag("low")
                            Text(t("Medium")).tag("medium"); Text(t("High")).tag("high")
                        }
                    }.padding(10)
                } label: { Text("OpenAI Responses") }
            case .deepSeek:
                SettingsSection {
                    VStack(alignment: .leading, spacing: 14) {
                        modelField("Reasoning model", value: $coordinator.settings.deepSeekModel)
                        Picker(t("Reasoning effort"), selection: $coordinator.settings.deepSeekEffort) {
                            Text(t("Off")).tag("none"); Text(t("Low (faster)")).tag("low")
                            Text(t("High")).tag("high"); Text(t("Maximum")).tag("max")
                        }
                        Text("https://api.deepseek.com/chat/completions").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(10)
                } label: { Text("DeepSeek") }
            case .compatible: customService
            }
            Text(t("Changes apply to the next answer. Existing knowledge vectors do not need re-indexing when you change only the analysis model.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var customService: some View {
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
                CredentialEditor(coordinator: coordinator, analysis: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            } else {
                Text(t("Save the service address before configuring its key.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func loadCustomDraft() {
        baseURL = coordinator.settings.compatibleBaseURL; apiPath = coordinator.settings.compatiblePath; customModel = coordinator.settings.compatibleModel
    }
    private func saveCustomConnection() {
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
    private func modelField(_ title: String, value: Binding<String>, prompt: String? = nil) -> some View {
        HStack {
            Text(t(title)).frame(width: 120, alignment: .leading)
            TextField(t(title), text: value, prompt: Text(prompt ?? t(title))).textFieldStyle(.roundedBorder)
        }
    }
    private var knowledge: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Local knowledge base")).font(.headline); Spacer()
                Button(t("Import documents…")) { selectDocuments() }.disabled(coordinator.isIndexing)
            }
            Text(t("PDF, Markdown, TXT and DOCX · original copies remain local. Indexing sends extracted text to OpenAI.")).font(.caption).foregroundStyle(.secondary)
            Stepper(t("Evidence chunks") + ": \(coordinator.settings.retrievalCount)", value: $coordinator.settings.retrievalCount, in: 3...8)
            if coordinator.isIndexing { ProgressView().controlSize(.small) }
            if !coordinator.knowledgeMessage.isEmpty { Text(t(coordinator.knowledgeMessage)).font(.caption).textSelection(.enabled) }
            List {
                ForEach(coordinator.knowledgeDocuments) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name).font(.headline)
                        Text("\(t(document.status)) · \(document.chunkCount) \(t("chunks")) · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary)
                        if let error = document.error { Text(t(error)).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button(t("Re-index")) { coordinator.reindex(document) }
                            Button(t("Show local copy")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.localPath)]) }
                            Spacer()
                            Button(t("Delete"), role: .destructive) { coordinator.deleteDocument(document) }
                        }.buttonStyle(.borderless).disabled(coordinator.isIndexing)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
            if coordinator.knowledgeDocuments.isEmpty { Text(t("Import a document to ground answers in your own evidence.")).foregroundStyle(.secondary) }
        }
    }
    private func selectDocuments() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK { coordinator.importDocuments(panel.urls) } }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Global shortcuts")).font(.headline)
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(t(mode.label), systemImage: mode.systemImage).frame(width: 130, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode), language: coordinator.settings.language) { coordinator.updateHotkey($0, for: mode) }.frame(width: 140, height: 28)
                    Button(t("Reset")) { coordinator.resetHotkey(mode) }
                }
            }
            Text(t("⌥H shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.")).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", services = "Services", knowledge = "Knowledge", shortcuts = "Shortcuts"
    var id: String { rawValue.lowercased() }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .services: return "shippingbox"
        case .knowledge: return "books.vertical"
        case .shortcuts: return "keyboard"
        }
    }
}

private struct CredentialStatus: View {
    @ObservedObject var coordinator: AppCoordinator
    let analysis: Bool
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private func t(_ value: String) -> String { L10n.text(value, language: coordinator.settings.language) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: available ? "checkmark.shield.fill" : "key.horizontal")
                .font(.title2).foregroundStyle(available ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(t(coordinator.isMock ? "Mock credential" : checking ? "Checking Keychain…" : available ? "API key configured" : "API key not configured")).font(.headline)
                if available && !coordinator.isMock {
                    Text("••••••••").font(.system(.body, design: .monospaced)).accessibilityLabel(t("Key hidden"))
                    Text(t("Credential ready. Its contents are never displayed here.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(t(analysis ? coordinator.analysisKeyStatus : coordinator.keyStatus)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
        }.accessibilityElement(children: .contain)
    }
}

private struct CredentialEditor: View {
    @ObservedObject var coordinator: AppCoordinator
    let analysis: Bool
    @State private var editing = false
    @State private var value = ""
    @State private var message = ""
    @State private var saving = false
    @State private var confirmingRemoval = false
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 14) {
                CredentialStatus(coordinator: coordinator, analysis: analysis)
                if editing || (!available && !checking) {
                    SecureField(t(available ? "Enter a replacement key" : "Enter a key to save in Keychain"), text: $value)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("credential-input")
                    HStack {
                        Button(t("Save Key")) { save() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || coordinator.isMock)
                        if available { Button(t("Cancel")) { editing = false; value = "" } }
                    }
                }
                HStack {
                    if available && !editing { Button(t("Replace key…")) { editing = true; message = "" }.disabled(coordinator.isMock) }
                    Button(t("Check Keychain")) { analysis ? coordinator.refreshAnalysisKeyState() : coordinator.refreshKeyState() }.disabled(checking || saving)
                    Spacer()
                    if available { Button(t("Remove"), role: .destructive) { confirmingRemoval = true }.disabled(saving || checking || coordinator.isMock) }
                }
                if !message.isEmpty { Text(t(message)).font(.caption).textSelection(.enabled) }
                if !analysis { Text(t("Uses your existing LiveCopilot-OpenAI Keychain item. No need to enter it again.")).font(.caption).foregroundStyle(.secondary) }
            }.padding(12)
        } label: { Text("API Key") }
        .confirmationDialog(t("Remove this service's saved key?"), isPresented: $confirmingRemoval) {
            Button(t("Remove"), role: .destructive) {
                Task {
                    saving = true; defer { saving = false }
                    do { try await coordinator.removeCredential(analysis: analysis); message = "Saved key removed." }
                    catch { message = error.localizedDescription }
                }
            }
            Button(t("Cancel"), role: .cancel) {}
        }
        .onDisappear { value = ""; editing = false }
    }
    private func save() {
        let key = value; value = ""; saving = true
        Task {
            defer { saving = false }
            do { try await coordinator.saveCredential(key, analysis: analysis); editing = false; message = "Saved in macOS Keychain." }
            catch { message = error.localizedDescription }
        }
    }
}

/// Explicit view grouping keeps section labels and controls accessible independently.
private struct SettingsSection<Content: View, Heading: View>: View {
    let content: Content
    let heading: Heading
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Heading) {
        self.content = content(); self.heading = label()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading.font(.headline)
            content.frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityElement(children: .contain)
    }
}
