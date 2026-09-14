import SwiftUI

struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var suggestion: SuggestionStore
    @State private var query = ""
    @State private var showTranscript = true
    @State private var followTranscript = true
    @State private var lastDragSize: CGSize?
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator; transcript = coordinator.transcript; suggestion = coordinator.suggestion
    }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(t(coordinator.statusMessage)).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if coordinator.isRunning {
                HStack {
                    Text(t(coordinator.questionState)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(t("Auto"), isOn: $coordinator.settings.automaticSuggestions).toggleStyle(.switch).controlSize(.mini)
                }
            }
            if showTranscript { transcriptView.frame(minHeight: 65, maxHeight: 145) }
            HStack(spacing: 6) {
                ForEach(SuggestionMode.allCases) { mode in
                    Button { coordinator.requestSuggestion(mode: mode) } label: { Label(t(mode.label), systemImage: mode.systemImage).font(.caption) }
                        .help(coordinator.hotkeys.combo(for: mode).display)
                }
                Spacer()
                Button { showTranscript.toggle() } label: { Image(systemName: "text.bubble") }.help(t("Show/hide conversation"))
            }
            Divider()
            answer
            HStack(alignment: .center) {
                TextField(t("Ask anything — listening can be off"), text: $query, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit { submit() }.accessibilityIdentifier("manual-query")
                Button(t("Ask")) { submit() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Toggle(t("Use recent conversation"), isOn: $coordinator.includeConversation).font(.caption2).toggleStyle(.checkbox)
                Spacer()
                if suggestion.isLoading { Button(t("Cancel")) { coordinator.cancelAnswer() }.font(.caption) }
            }
            footer
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if coordinator.settings.background == .white { RoundedRectangle(cornerRadius: 16).fill(Color.white) }
                else { RoundedRectangle(cornerRadius: 16).fill(.regularMaterial) }
            }
            .preferredColorScheme(coordinator.settings.background == .white ? .light : nil)
            .environment(\.locale, coordinator.settings.language.locale)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
            .overlay(alignment: .bottomTrailing) { resizeHandle }
    }
    private func submit() { let value = query; query = ""; coordinator.askText(value) }
    private var header: some View {
        HStack {
            Text(t("LiveCopilot")).font(.headline)
            if coordinator.isMock { Text(t("MOCK")).font(.caption2.bold()).foregroundStyle(.orange) }
            Spacer()
            Button { Task { await coordinator.toggle() } } label: {
                Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(coordinator.isRunning ? Color.red : .green)
            }.disabled(coordinator.isTransitioning).help(t(coordinator.isRunning ? "Stop listening" : "Start listening"))
            Button { coordinator.toggleMic() } label: { Image(systemName: coordinator.micEnabled ? "mic.fill" : "mic.slash") }
                .help(t("Toggle your microphone in Remote Meeting mode"))
            Button { coordinator.onOpenSettings?() } label: { Image(systemName: "gearshape") }.help(t("Settings and knowledge base"))
            Button { NSApp.windows.first(where: { $0 is OverlayWindow })?.orderOut(nil) } label: { Image(systemName: "minus") }.help(t("Hide (⌥H)"))
        }.buttonStyle(.borderless)
    }
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 2) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if transcript.lines.isEmpty { Text(t("Conversation appears here when listening.")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(transcript.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(t(line.speaker.rawValue)).font(.caption2.bold()).foregroundStyle(line.speaker == .you ? Color.blue : .green).frame(width: 35, alignment: .leading)
                                Text(line.content).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                }.onChange(of: transcript.lines) { _, _ in if followTranscript { proxy.scrollTo("latest", anchor: .bottom) } }
                Toggle(t("Follow transcript"), isOn: $followTranscript).font(.caption2).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if !suggestion.question.isEmpty { Text(suggestion.question).font(.subheadline.bold()).textSelection(.enabled) }
                if let warning = suggestion.warning { Text(t(warning)).font(.caption).foregroundStyle(.orange) }
                if suggestion.isLoading && suggestion.text.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(t("Retrieving evidence and thinking…")).font(.caption) }
                }
                if suggestion.text.isEmpty && !suggestion.isLoading && suggestion.error == nil {
                    Text(t("Ask a question below, or use ⌥Space for help with the conversation.")).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(SuggestionParser.sections(suggestion.text).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t(section.title)).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(.init(section.content)).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error = suggestion.error { Text(t(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !suggestion.sources.isEmpty {
                    Divider()
                    Text(t("Sources · retrieved local evidence")).font(.caption.bold())
                    ForEach(Array(suggestion.sources.enumerated()), id: \.element.id) { i, source in
                        DisclosureGroup("[S\(i + 1)] \(source.chunk.displayLabel(language: coordinator.settings.language))") {
                            Text(source.chunk.text).font(.caption).textSelection(.enabled)
                        }.font(.caption2)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack {
            Text(t(coordinator.settings.scenario.rawValue)).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let ms = suggestion.firstTextMS { Text("\(t("First text")) \(Double(ms) / 1000, specifier: "%.1f")s").font(.caption2).foregroundStyle(.secondary) }
            if !suggestion.text.isEmpty {
                Button(t("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(suggestion.text, forType: .string) }.font(.caption2)
            }
            Text(t("⌥H")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right").font(.system(size: 9)).padding(4).contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                guard let window = NSApp.windows.first(where: { $0 is OverlayWindow }) else { return }
                if lastDragSize == nil { lastDragSize = window.frame.size }
                guard let size = lastDragSize else { return }
                let width = min(max(size.width + value.translation.width, window.minSize.width), window.maxSize.width)
                let height = min(max(size.height - value.translation.height, window.minSize.height), window.maxSize.height)
                var frame = window.frame; frame.origin.y += frame.height - height; frame.size = CGSize(width: width, height: height)
                window.setFrame(frame, display: true)
            }.onEnded { _ in lastDragSize = nil })
    }
}
