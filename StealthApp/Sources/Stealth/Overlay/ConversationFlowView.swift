import SwiftUI
import AppKit

/// Content growth alone must never turn following off. Only moving upward does.
struct ConversationScrollState {
    var followsLatest = true
    private var lastOffset: CGFloat = 0
    private var lastViewportHeight: CGFloat?
    mutating func observe(offset: CGFloat, distanceToBottom: CGFloat, viewportHeight: CGFloat? = nil) {
        let resized = viewportHeight.map { height in lastViewportHeight.map { abs($0 - height) > 0.5 } ?? true } ?? false
        if !resized && offset < lastOffset - 1 { followsLatest = false }
        lastViewportHeight = viewportHeight
        if distanceToBottom <= 24 { followsLatest = true }
        lastOffset = offset
    }
    mutating func jumpToLatest() { followsLatest = true }
}

private final class ConversationScrollController {
    var state = ConversationScrollState()
    private var pendingScroll: DispatchWorkItem?
    private var lastScrollAt: TimeInterval = 0

    func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        guard state.followsLatest else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0.016, 0.1 - (now - lastScrollAt))
        guard pendingScroll == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScroll = nil
            guard self.state.followsLatest else { return }
            self.lastScrollAt = ProcessInfo.processInfo.systemUptime
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
        pendingScroll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reset() {
        pendingScroll?.cancel()
        pendingScroll = nil
        state = ConversationScrollState()
    }

    func cancel() {
        pendingScroll?.cancel()
        pendingScroll = nil
    }
}

struct ConversationFlowView: View {
    @ObservedObject var coordinator: AppCoordinator
    let fontSize: CGFloat
    var onContentHeight: (CGFloat) -> Void = { _ in }
    @State private var scrollController = ConversationScrollController()
    @State private var followsLatest = true
    @State private var hasNewAnswer = false
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                LCScrollView {
                    // Not LazyVStack: lazy placement re-estimates offscreen answer heights and,
                    // with a long, selectable answer history, could keep re-running layout inside
                    // one SwiftUI update (2.10 froze the main thread for minutes). A session holds
                    // tens of answers at most, so laying them all out once is cheap and exact.
                    VStack(alignment: .leading, spacing: 18) {
                        if coordinator.answers.isEmpty {
                            LCEmptyState(systemImage: "sparkles", title: b("Answers appear here", "回答会出现在这里"),
                                         message: b("Ask above, or start listening to receive suggestions.", "在上方输入问题，或开始监听以获取回答。"),
                                         compact: true)
                                .padding(.vertical, 8)
                        }
                        ForEach(coordinator.answers) { record in
                            AnswerMessageView(record: record, store: record.store, language: coordinator.settings.language, fontSize: fontSize)
                                .id(record.id)
                        }
                        Color.clear.frame(height: 8).id("conversation-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { measured in
                        // Clamp: the window never needs more than this to size itself.
                        Color.clear.preference(key: ConversationContentHeightKey.self, value: min(measured.size.height, 1200))
                    })
                    .background(ConversationScrollObserver { offset, distance, height in
                        scrollController.state.observe(offset: offset, distanceToBottom: distance, viewportHeight: height)
                        let nextFollows = scrollController.state.followsLatest
                        if followsLatest != nextFollows { followsLatest = nextFollows }
                        if nextFollows && hasNewAnswer { hasNewAnswer = false }
                    })
                }.accessibilityIdentifier("conversation-flow")
                if !followsLatest {
                    Button {
                        scrollController.state.jumpToLatest()
                        followsLatest = true
                        hasNewAnswer = false
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    } label: {
                        ConversationJumpLabel(title: hasNewAnswer ? b("New answer · Jump to latest", "有新回答 · 跳到最新") : b("Jump to latest", "回到最新"))
                    }.buttonStyle(.plain).padding(.trailing, 18).padding(.bottom, 10)
                        .accessibilityIdentifier("jump-to-latest")
                }
            }
            .onPreferenceChange(ConversationContentHeightKey.self, perform: onContentHeight)
            // The empty state reads from the top; bottom-anchoring it would cut off its title.
            .onAppear { if !coordinator.answers.isEmpty { scrollController.scheduleScrollToBottom(proxy: proxy) } }
            .onDisappear { scrollController.cancel() }
            .onChange(of: coordinator.answerRevision) { _, _ in
                if scrollController.state.followsLatest {
                    scrollController.scheduleScrollToBottom(proxy: proxy)
                } else if !hasNewAnswer { hasNewAnswer = true }
            }
            .onChange(of: coordinator.conversationGeneration) { _, _ in
                scrollController.reset()
                if !followsLatest { followsLatest = true }
                if hasNewAnswer { hasNewAnswer = false }
            }
        }
    }
}

private struct ConversationContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ConversationJumpLabel: View {
    let title: String
    var body: some View {
        Label(title, systemImage: "arrow.down")
            .font(.caption.weight(.semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ConversationJumpBackdrop().allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LC.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
    }
}

/// Blur the answer text inside this window, even when the floating panel is inactive.
private struct ConversationJumpBackdrop: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .popover
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

struct AnswerMessageView: View {
    let record: AppCoordinator.AnswerRecord
    @ObservedObject var store: SuggestionStore
    let language: AppLanguage
    let fontSize: CGFloat
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    private func t(_ value: String) -> String { L10n.text(value, language: language) }
    private var status: String {
        switch store.state {
        case .queued: return b("Queued", "待生成")
        case .generating: return b("Generating", "生成中")
        case .completed: return b("Completed", "已完成")
        case .interrupted: return b("Interrupted", "已中断")
        case .failed: return b("Failed", "生成失败")
        }
    }
    private var statusTone: LC.Tone {
        switch store.state {
        case .queued: return .neutral
        case .generating: return .accent
        case .completed: return .success
        case .interrupted: return .warning
        case .failed: return .danger
        }
    }
    static func isEvidence(_ title: String) -> Bool {
        let key = title.lowercased()
        return key.contains("依据") || key.contains("依據") || key.contains("evidence") || key.contains("notes") || key.contains("证据") || key.contains("备注") || key.contains("说明")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LCPill(text: record.automatic ? b("Automatic suggestion", "自动建议") : b("Manual question", "手动提问"),
                           tone: record.automatic ? .pink : .accent, systemImage: record.automatic ? "waveform" : "text.bubble")
                    if record.merged {
                        LCPill(text: b("Addition merged", "已合并补充"), tone: .neutral, systemImage: "arrow.triangle.merge")
                            .accessibilityIdentifier("answer-merged")
                    }
                    Spacer()
                    Text(record.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(store.question).font(.system(size: fontSize, weight: .semibold))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10)
                .background(LC.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous).strokeBorder(LC.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    LCPill(text: status, tone: statusTone)
                    Spacer()
                    if !store.text.isEmpty {
                        CopyAnswerButton(label: t("Copy"), copiedLabel: b("Copied", "已复制")) {
                            AnswerEmphasis.plainText(store.text, streaming: store.isLoading)
                        }
                    }
                }
                if store.isLoading { LCProgressLine().transition(.opacity) }
                if store.isLoading && store.text.isEmpty { Text(t(store.waitingMessage)).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(SuggestionParser.sections(store.text).enumerated()), id: \.offset) { _, section in
                    if Self.isEvidence(section.title) {
                        DisclosureGroup(t("Evidence & notes")) {
                            Text(.init(section.content)).font(.system(size: fontSize)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }.font(.caption)
                    } else {
                        HighlightedAnswerText(content: section.content, fontSize: fontSize, streaming: store.isLoading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let warning = store.warning { Text(t(warning)).font(.caption).foregroundStyle(LC.warning) }
                if let error = store.error { Text(t(error)).font(.caption).foregroundStyle(LC.danger).textSelection(.enabled) }
                if !store.citedSources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("Sources")).font(LC.Typo.micro).foregroundStyle(.secondary)
                        LCFlowLayout(spacing: 6) {
                            ForEach(store.citedSources, id: \.index) { citation in
                                CitationChip(index: citation.index, chunk: citation.source.chunk, language: language)
                            }
                        }
                    }.padding(.top, 2)
                }
            }.padding(.horizontal, 10)
            .lcAnimation(LC.Motion.standard, value: store.isLoading)
        }.accessibilityIdentifier("answer-card-" + record.id.uuidString)
    }
}

/// Observes the native clip view without intercepting wheel, keyboard or selection events.
private struct ConversationScrollObserver: NSViewRepresentable {
    var changed: (CGFloat, CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.changed = changed; return view }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.changed = changed; nsView.attach() }
    final class Probe: NSView {
        var changed: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observation: NSObjectProtocol?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView, self.clip !== scrollView.contentView else { return }
                if let observation = self.observation { NotificationCenter.default.removeObserver(observation) }
                self.clip = scrollView.contentView
                scrollView.contentView.postsBoundsChangedNotifications = true
                self.observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self, weak scrollView] _ in
                    // Read settled geometry, rather than an intermediate layout
                    // snapshot from before the window's automatic resize.
                    DispatchQueue.main.async { [weak self, weak scrollView] in
                        guard let self, let view = scrollView, self.clip === view.contentView,
                              let document = view.documentView else { return }
                        let bounds = view.contentView.bounds
                        self.changed?(bounds.minY, max(0, document.bounds.height - bounds.maxY), bounds.height)
                    }
                }
            }
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}

/// Native attributed text keeps emphasis backgrounds, selection and wrapping on macOS 14.
struct HighlightedAnswerText: NSViewRepresentable {
    let content: String
    let fontSize: CGFloat
    var streaming = false
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        var lastKey: (content: String, fontSize: CGFloat, streaming: Bool, isDark: Bool)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layout = CrayonLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let view = NSTextView(frame: .zero, textContainer: container)
        view.textContainerInset = .zero
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let isDark = colorScheme == .dark
        if let last = context.coordinator.lastKey,
           last.content == content, last.fontSize == fontSize,
           last.streaming == streaming, last.isDark == isDark {
            return
        }
        context.coordinator.lastKey = (content, fontSize, streaming, isDark)
        let parsed = AnswerEmphasis.parsed(content, streaming: streaming)
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (fontSize * 0.32).rounded()
        paragraph.paragraphSpacing = (fontSize * 0.45).rounded()
        for run in parsed.runs {
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: strong ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: strong ? .semibold : .regular)
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true, let font = attributes[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            let phrase = String(parsed[run.range].characters)
            if strong { attributes[CrayonLayoutManager.mark] = isDark }
            result.append(NSAttributedString(string: phrase, attributes: attributes))
        }
        if streaming && result.length > 0 {
            // A thin caret marks where text is still arriving.
            result.append(NSAttributedString(string: " ▍", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.9, weight: .light),
                .foregroundColor: NSColor(LC.accent).withAlphaComponent(0.7),
                .paragraphStyle: paragraph
            ]))
        }
        if view.textStorage?.isEqual(to: result) != true {
            view.textStorage?.setAttributedString(result)
            view.invalidateIntrinsicContentSize()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).maxY))
    }
}

private final class CrayonLayoutManager: NSLayoutManager {
    static let mark = NSAttributedString.Key("LiveCopilotCrayon")
    private let textures = NSCache<NSString, NSImage>()

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(Self.mark, in: characters) { value, range, _ in
            guard let dark = value as? Bool else { return }
            let marked = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: marked) { _, _, container, line, _ in
                let fragment = NSIntersectionRange(line, marked)
                guard fragment.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: fragment, in: container)
                rect.origin.x += origin.x
                rect.origin.y += origin.y + rect.height * 0.49
                rect.size.height *= 0.45
                guard rect.width > 0, rect.height > 0 else { return }
                self.texture(for: rect.size, dark: dark).draw(in: rect, from: .zero, operation: .sourceOver,
                                                             fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        super.drawBackground(forGlyphRange: glyphs, at: origin)
    }

    // Generate a stable pigment mask at Retina resolution. Repainting a stream reuses the same grain.
    private func texture(for size: CGSize, dark: Bool) -> NSImage {
        let w = min(4096, max(2, Int(ceil(size.width * 2))))
        let h = min(256, max(2, Int(ceil(size.height * 2))))
        let key = "\(w)-\(h)-\(dark)" as NSString
        if let image = textures.object(forKey: key) { return image }
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied, bytesPerRow: w * 4, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { return image }
        var seed: UInt32 = 271828
        func noise() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / 16777216
        }
        for y in 0..<h {
            let row = Double(y) / Double(h - 1)
            let pressure = 0.72 + noise() * 0.28
            let left = noise() * 0.48, right = noise() * 0.48
            for x in 0..<w {
                let t = Double(x) / Double(w - 1)
                let center = 0.52 + 0.07 * sin(Double(x) / 21) + 0.035 * sin(Double(x) / 7)
                let edge = max(0, min(1, (0.48 - abs(row - center)) * 6))
                let tip = max(0, min(1, min(Double(x)/Double(h) - left, Double(w-1-x)/Double(h) - right) * 2))
                let grain = noise()
                let alpha = edge * tip * pressure * (grain < 0.16 ? 0.08 : 0.25 + grain * 0.75)
                let i = (y*w+x)*4
                pixels[i] = UInt8(62 + 179*t)
                pixels[i+1] = UInt8(164 - 47*t)
                pixels[i+2] = UInt8(234 - 66*t)
                pixels[i+3] = UInt8((dark ? 203 : 155) * alpha)
            }
        }
        bitmap.size = size
        image.addRepresentation(bitmap)
        textures.totalCostLimit = 4 * 1024 * 1024
        textures.setObject(image, forKey: key, cost: w*h*4)
        return image
    }
}


/// Copies the answer and confirms with a checkmark for a moment.
private struct CopyAnswerButton: View {
    let label: String
    let copiedLabel: String
    let text: () -> String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
        } label: {
            Label(copied ? copiedLabel : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(LCButtonStyle(kind: copied ? .ghost : .secondary, compact: true))
        .lcAnimation(LC.Motion.quick, value: copied)
        .help(label)
    }
}

/// [S1] source pill; click shows the cited excerpt.
private struct CitationChip: View {
    let index: Int
    let chunk: SourceChunk
    let language: AppLanguage
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Text("S\(index)").font(LC.Typo.micro.weight(.bold)).foregroundStyle(LC.accent)
                Text(chunk.documentName).font(LC.Typo.caption).lineLimit(1).truncationMode(.middle)
                if let page = chunk.page {
                    Text(language.usesChinese ? "第 \(page) 页" : "p.\(page)").font(LC.Typo.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 22)
            .frame(maxWidth: 240)
            .background(LC.fillSubtle, in: Capsule())
            .overlay(Capsule().strokeBorder(LC.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .lcHoverable(radius: 11)
        .help(chunk.displayLabel(language: language))
        .accessibilityLabel("S\(index) " + chunk.displayLabel(language: language))
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    LCPill(text: "S\(index)", tone: .accent)
                    Text(chunk.displayLabel(language: language)).font(LC.Typo.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                LCScrollView {
                    Text(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(LC.Typo.callout).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
            .padding(14).frame(width: 340)
        }
    }
}
