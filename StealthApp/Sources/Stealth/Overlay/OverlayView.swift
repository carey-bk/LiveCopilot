import SwiftUI

/// The translucent card shown in the stealth overlay:
///  - a thin live transcript strip (the "bonus" feature)
///  - the suggested reply card (the core feature), populated on hotkey.
struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var suggestion: SuggestionStore

    /// Window size captured at the start of a resize drag (cumulative-translation baseline).
    @State private var lastDragSize: CGSize?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.transcript = coordinator.transcript
        self.suggestion = coordinator.suggestion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcriptStrip            // expands to fill available height
            Divider().overlay(Color.white.opacity(0.12))
            actionRow
            suggestionCard
            footer
        }
        .padding(14)
        // Fill the whole (resizable) window instead of a fixed size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    /// Bottom-right drag handle that resizes the window (borderless panels hide
    /// the native grip). Dragging changes the window's frame live.
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in resizeWindow(translation: value.translation) }
                    .onEnded { _ in lastDragSize = nil }
            )
            .help("Drag to resize")
    }

    private func resizeWindow(translation: CGSize) {
        guard let window = NSApp.windows.first(where: { $0 is OverlayWindow }) else { return }
        // Capture the size once at drag start; translation is cumulative from there.
        if lastDragSize == nil { lastDragSize = window.frame.size }
        let start = lastDragSize!

        let minS = window.minSize, maxS = window.maxSize
        let newW = min(max(start.width + translation.width, minS.width), maxS.width)
        let newH = min(max(start.height - translation.height, minS.height), maxS.height)

        var frame = window.frame
        // Keep the top-left anchored while the bottom-right corner moves.
        frame.origin.y += frame.size.height - newH
        frame.size = NSSize(width: newW, height: newH)
        window.setFrame(frame, display: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Tap to start / stop listening.
            Button {
                Task { await coordinator.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(coordinator.isRunning ? Color.red : Color.green)
                    Text(coordinator.isRunning ? "Listening" : "Idle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.hasAPIKey)
            .help(coordinator.isRunning ? "Stop listening" : "Start listening")

            // Mute / unmute your mic (stops the "You" side; use when speaker bleed
            // is being double-transcribed, or on speakerphone).
            Button {
                coordinator.toggleMic()
            } label: {
                Image(systemName: coordinator.micEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(coordinator.micEnabled ? Color.blue : Color.gray.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(coordinator.micEnabled ? "Mute mic (You)" : "Unmute mic (You)")

            Spacer()
            Button {
                transcript.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Clear transcript")
            Text("⌥H hide")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// Tap-to-trigger row: Reply / Recap / Follow-up. Mirrors the global hotkeys.
    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(SuggestionMode.allCases) { mode in
                Button {
                    coordinator.requestSuggestion(mode: mode)
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .foregroundStyle(coordinator.isRunning ? .primary : .tertiary)
                .help("\(coordinator.hotkeys.combo(for: mode).display) — \(mode.label)")
                .disabled(!coordinator.isRunning)
            }
        }
    }

    /// Scrollable, speaker-labelled, timestamped transcript that auto-scrolls.
    private var transcriptStrip: some View {
        let lines = transcript.lines
        let pThem = transcript.partialThem
        let pYou = transcript.partialYou
        let isEmpty = lines.isEmpty && pThem.isEmpty && pYou.isEmpty

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if isEmpty {
                        Text("Waiting for speech…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lines) { line in
                            transcriptRow(speaker: line.speaker,
                                          clock: line.clock,
                                          text: line.content,
                                          dim: false)
                        }
                        // In-progress lines, dimmer, no timestamp yet.
                        if !pYou.isEmpty {
                            transcriptRow(speaker: .you, clock: nil, text: pYou, dim: true)
                        }
                        if !pThem.isEmpty {
                            transcriptRow(speaker: .them, clock: nil, text: pThem, dim: true)
                        }
                    }
                    Color.clear.frame(height: 1).id(scrollAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Expand to fill the window's available height (min 90 so it stays usable).
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .leading)
            .onChange(of: lines.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pThem) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pYou) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    @ViewBuilder
    private func transcriptRow(speaker: Speaker, clock: String?, text: String, dim: Bool) -> some View {
        let accent: Color = speaker == .you ? .blue : .green
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(speaker.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                if let clock {
                    Text(clock)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(dim ? .tertiary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private let scrollAnchor = "transcript-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(scrollAnchor, anchor: .bottom)
        }
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestion.text.isEmpty || suggestion.isLoading {
                Label(suggestion.mode.label, systemImage: suggestion.mode.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            Group {
                if let error = suggestion.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else if suggestion.isLoading && suggestion.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else if suggestion.text.isEmpty {
                    Text("Tap Reply, Recap, or Follow-up above.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(suggestion.text)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("Tone: \(coordinator.tone.label)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(AppInfo.display)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if !suggestion.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(suggestion.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}
