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

struct ConversationFlowView: View {
    @ObservedObject var coordinator: AppCoordinator
    let fontSize: CGFloat
    var onContentHeight: (CGFloat) -> Void = { _ in }
    @State private var scroll = ConversationScrollState()
    @State private var hasNewAnswer = false
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if coordinator.answers.isEmpty {
                            Text(b("Ask above, or start listening to receive suggestions.", "在上方输入问题，或开始监听以获取回答。"))
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(coordinator.answers) { record in
                            AnswerMessageView(record: record, store: record.store, language: coordinator.settings.language, fontSize: fontSize)
                                .id(record.id)
                        }
                        Color.clear.frame(height: 8).id("conversation-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { measured in
                        Color.clear.preference(key: ConversationContentHeightKey.self, value: measured.size.height)
                    })
                    .background(ConversationScrollObserver { offset, distance, height in
                        scroll.observe(offset: offset, distanceToBottom: distance, viewportHeight: height)
                        if scroll.followsLatest { hasNewAnswer = false }
                    })
                }.accessibilityIdentifier("conversation-flow")
                if !scroll.followsLatest {
                    Button {
                        scroll.jumpToLatest(); hasNewAnswer = false
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    } label: {
                        ConversationJumpLabel(title: hasNewAnswer ? b("New answer · Jump to latest", "有新回答 · 跳到最新") : b("Jump to latest", "回到最新"))
                    }.buttonStyle(.plain).padding(.trailing, 18).padding(.bottom, 10)
                        .accessibilityIdentifier("jump-to-latest")
                }
            }
            .onPreferenceChange(ConversationContentHeightKey.self, perform: onContentHeight)
            .onAppear { DispatchQueue.main.async { if scroll.followsLatest { proxy.scrollTo("conversation-bottom", anchor: .bottom) } } }
            .onChange(of: coordinator.answerRevision) { _, _ in
                if scroll.followsLatest {
                    // Let the new card or streaming text complete layout first.
                    DispatchQueue.main.async { if scroll.followsLatest { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
                } else { hasNewAnswer = true }
            }
            .onChange(of: coordinator.conversationGeneration) { _, _ in
                scroll = ConversationScrollState(); hasNewAnswer = false
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
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.14)))
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
    static func isEvidence(_ title: String) -> Bool {
        let key = title.lowercased()
        return key.contains("依据") || key.contains("依據") || key.contains("evidence") || key.contains("notes") || key.contains("证据") || key.contains("备注") || key.contains("说明")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(record.automatic ? b("Automatic suggestion", "自动建议") : b("Manual question", "手动提问"),
                          systemImage: record.automatic ? "waveform" : "text.bubble")
                    Spacer()
                    Text(record.createdAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
                Text(store.question).font(.system(size: fontSize, weight: .semibold))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    if store.isLoading { ProgressView().controlSize(.mini) }
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if !store.text.isEmpty {
                        Button(t("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AnswerEmphasis.plainText(store.text, streaming: store.isLoading), forType: .string) }
                            .font(.caption2).buttonStyle(.borderless)
                    }
                }
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
                if let warning = store.warning { Text(t(warning)).font(.caption).foregroundStyle(.orange) }
                if let error = store.error { Text(t(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !store.citedSources.isEmpty {
                    DisclosureGroup(t("Sources")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.citedSources, id: \.index) { citation in
                                Text("[S\(citation.index)] \(citation.source.chunk.displayLabel(language: language))")
                                    .font(.caption.bold()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 4)
                    }.font(.caption)
                }
            }.padding(.horizontal, 10)
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
        let parsed = AnswerEmphasis.parsed(content, streaming: streaming)
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: strong ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor
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
            if strong { attributes[CrayonLayoutManager.mark] = colorScheme == .dark }
            result.append(NSAttributedString(string: phrase, attributes: attributes))
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
