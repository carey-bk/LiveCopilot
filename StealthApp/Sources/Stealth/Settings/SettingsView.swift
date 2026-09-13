import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @State private var apiKeyField = ""
    @State private var keyMessage = ""
    @State private var tab = 0
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; hotkeys = coordinator.hotkeys }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LiveCopilot").font(.title2.bold())
                Spacer()
                Text(coordinator.isMock ? "MOCK — no API calls" : AppInfo.display).font(.caption).foregroundStyle(.secondary)
            }
            TabView(selection: $tab) {
                ScrollView { general.padding(16) }.tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(0)
                knowledge.padding(16).tabItem { Label("Knowledge", systemImage: "books.vertical") }.tag(1)
                shortcuts.padding(16).tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(2)
            }
        }.padding(20).frame(width: 620, height: 590)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("OpenAI API Key").font(.headline)
            SecureField("Enter a key to save in Keychain", text: $apiKeyField).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Key") {
                    do { try KeychainStore.save(apiKeyField); apiKeyField = ""; coordinator.refreshKeyState(); keyMessage = "Saved in macOS Keychain." }
                    catch { keyMessage = error.localizedDescription }
                }.disabled(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isMock)
                Button("Check Keychain") { keyMessage = ""; coordinator.refreshKeyState() }.disabled(coordinator.isCheckingKey)
                Button("Remove saved key", role: .destructive) {
                    do { try KeychainStore.clear(); coordinator.refreshKeyState(); keyMessage = "Saved key removed." }
                    catch { keyMessage = error.localizedDescription }
                }.disabled(coordinator.isMock)
            }
            if !keyMessage.isEmpty { Text(keyMessage).font(.caption).textSelection(.enabled) }
            Text(coordinator.keyStatus).font(.caption).textSelection(.enabled)
            Text("Keychain: LiveCopilot-OpenAI / current macOS user. OPENAI_API_KEY is the development fallback.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Group {
                Picker("Operating mode", selection: $coordinator.settings.mode) { ForEach(OperatingMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Scenario", selection: $coordinator.settings.scenario) { ForEach(ScenarioProfile.allCases) { Text($0.rawValue).tag($0) } }
                modelField("Live model", value: $coordinator.settings.liveModel)
                modelField("Reasoning model", value: $coordinator.settings.reasoningModel)
                modelField("Embedding model", value: $coordinator.settings.embeddingModel)
                Picker("Reasoning effort", selection: $coordinator.settings.reasoningEffort) {
                    Text("Model default").tag("")
                    Text("Low (faster)").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
            }.disabled(coordinator.isRunning || coordinator.isTransitioning)
            if coordinator.isRunning { Text("Stop listening to change mode, scenario or models.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Automatic suggestions for meaningful questions", isOn: $coordinator.settings.automaticSuggestions)
            Stepper("Retrieve \(coordinator.settings.retrievalCount) evidence chunks", value: $coordinator.settings.retrievalCount, in: 3...8)
            Text("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Privacy").font(.headline)
            Text("Files, chunks, vectors and session history stay on this Mac. Live audio goes to OpenAI while listening. Indexing sends document text to OpenAI Embeddings; queries send the question, relevant conversation and retrieved evidence to OpenAI. Output is text only.").font(.caption)
            Text("The overlay requests capture exclusion using macOS APIs. Verify it with your meeting app before relying on it.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func modelField(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title).frame(width: 125, alignment: .leading); TextField(title, text: value).textFieldStyle(.roundedBorder) }
    }
    private var knowledge: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local knowledge base").font(.headline)
                Spacer()
                Button("Import documents…") { selectDocuments() }.disabled(coordinator.isIndexing)
            }
            Text("PDF, Markdown, TXT and DOCX · original copies remain local. Indexing sends extracted text to OpenAI.").font(.caption).foregroundStyle(.secondary)
            if coordinator.isIndexing { ProgressView().controlSize(.small) }
            Text(coordinator.knowledgeMessage).font(.caption).textSelection(.enabled)
            List {
                ForEach(coordinator.knowledgeDocuments) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name).font(.headline)
                        Text("\(document.status) · \(document.chunkCount) chunks · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary)
                        if let error = document.error { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button("Re-index") { coordinator.reindex(document) }
                            Button("Show local copy") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.localPath)]) }
                            Spacer()
                            Button("Delete", role: .destructive) { coordinator.deleteDocument(document) }
                        }.buttonStyle(.borderless).disabled(coordinator.isIndexing)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                }
            }
            if coordinator.knowledgeDocuments.isEmpty { Text("Import a document to ground answers in your own evidence.").foregroundStyle(.secondary) }
        }
    }
    private func selectDocuments() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { coordinator.importDocuments(panel.urls) }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Global shortcuts").font(.headline)
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(mode.label, systemImage: mode.systemImage).frame(width: 130, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode)) { coordinator.updateHotkey($0, for: mode) }.frame(width: 130, height: 25)
                    Button("Reset") { coordinator.resetHotkey(mode) }
                }
            }
            Text("⌥H shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.").font(.caption)
            Spacer()
        }
    }
}
