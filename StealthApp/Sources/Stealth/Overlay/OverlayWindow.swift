import AppKit
import SwiftUI

/// A floating, always-on-top panel that requests exclusion from screen capture.
///
/// The stealth properties:
///  - `sharingType = .none` requests exclusion; verify in the actual sharing app.
///  - `.floating` level + joins all Spaces → stays above fullscreen calls.
///  - non-activating panel → clicking it never steals focus from the meeting.
final class OverlayWindow: NSPanel {
    private(set) var autoHeight = true
    private(set) var edgeHide = false
    private(set) var edgeHidden = false
    var onManualHeight: (() -> Void)?
    private var desiredHeight: CGFloat = 280
    private var edgeTimer: Timer?
    private var hover = OverlayHoverState()
    private var holdUntil: TimeInterval = 0
    private var geometryTask: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var transition = UUID()
    private var targetScreen: NSScreen?
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Resize bounds.
        minSize = NSSize(width: 400, height: 240)
        maxSize = NSSize(width: 700, height: 1000)

        // --- Stealth: stay out of screen capture ---
        sharingType = .none

        // --- Always-on-top across every Space, including over fullscreen apps ---
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // --- Don't steal focus from the call ---
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // --- Transparent chrome; SwiftUI draws the translucent card ---
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [] // This window owns its bounds; an empty SwiftUI view must not cap them.
        contentView = OverlayResizeView(content: hosting)

        positionTopRight()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.targetScreen = nil
                self.fitHeight(animated: false)
            }
        }
    }

    /// Borderless panels can't normally become key; allow it so text is selectable if needed.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: visible.maxX - frame.width - margin,
            y: visible.maxY - frame.height - margin
        )
        setFrameOrigin(origin)
    }

    func configure(autoHeight: Bool, edgeHide: Bool) {
        let heightChanged = self.autoHeight != autoHeight
        self.autoHeight = autoHeight
        if self.edgeHide != edgeHide {
            self.edgeHide = edgeHide
            isMovableByWindowBackground = !edgeHide
            hover.reset()
            if edgeHide {
                targetScreen = screen ?? NSScreen.main
                fitHeight(animated: false)
                tuckAway(animated: false)
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pollEdge() }
                }
                timer.tolerance = 0.035
                RunLoop.main.add(timer, forMode: .common)
                edgeTimer = timer
            } else {
                edgeTimer?.invalidate(); edgeTimer = nil
                reveal()
            }
        }
        if heightChanged { fitHeight(animated: true) }
    }

    func contentHeightChanged(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(desiredHeight - height) > 1 else { return }
        desiredHeight = height
        // Throttle streaming updates without postponing growth until the stream finishes.
        guard geometryTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometryTask = nil
            if self.autoHeight { self.fitHeight(animated: true) }
        }
        geometryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    func minimumContentHeightChanged(_ height: CGFloat) {
        guard height.isFinite, let screen = displayScreen else { return }
        let minimum = min(max(240, height), screen.visibleFrame.height - 24)
        guard abs(minSize.height - minimum) > 1 else { return }
        minSize.height = minimum
        fitHeight(animated: false)
    }

    private var displayScreen: NSScreen? {
        if !edgeHide, let screen { return screen }
        if let targetScreen, NSScreen.screens.contains(where: { $0 == targetScreen }) { return targetScreen }
        return screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func fitHeight(animated: Bool) {
        guard let display = displayScreen else { return }
        let fitted = OverlayLayout.fitted(frame, height: max(minSize.height, autoHeight ? desiredHeight : frame.height),
                                         visible: display.visibleFrame, docked: edgeHide)
        guard fitted != frame else { return }
        // Keep the top edge stable. Hidden content can grow without revealing the window.
        // Overlapping NSWindow frame animations can leave the hosting view at an
        // obsolete height while streaming/revealing. Apply geometry atomically.
        setFrame(fitted, display: isVisible)
        contentView?.layoutSubtreeIfNeeded()
        invalidateShadow()
    }

    func userFinishedResize(vertical: Bool) {
        if vertical { autoHeight = false; onManualHeight?() }
        if !edgeHide { targetScreen = screen }
        fitHeight(animated: false)
    }

    private func pollEdge() {
        let typing = isKeyWindow && (firstResponder as? NSTextView)?.isEditable == true
        updatePointer(NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                      interacting: typing || NSEvent.pressedMouseButtons != 0 || attachedSheet != nil)
    }

    func updatePointer(_ point: NSPoint, now: TimeInterval, interacting: Bool) {
        guard edgeHide else { return }
        if edgeHidden || !isVisible {
            let hit = NSScreen.screens.first { OverlayLayout.atRightEdge(point, screen: $0.frame, visible: $0.visibleFrame) }
            if hover.shouldReveal(atEdge: hit != nil, now: now), let hit {
                targetScreen = hit
                reveal()
            }
        } else {
            if hover.shouldHide(inside: frame.insetBy(dx: -12, dy: -12).contains(point), interacting: interacting || now < holdUntil, now: now) {
                tuckAway()
            }
        }
    }

    func reveal() {
        transition = UUID()
        let wasHidden = edgeHidden || !isVisible
        edgeHidden = false; hover.reset()
        holdUntil = ProcessInfo.processInfo.systemUptime + 1.2
        fitHeight(animated: false)
        alphaValue = 1
        orderFrontRegardless()
        if wasHidden && edgeHide && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().alphaValue = 1
            }
        }
    }

    func tuckAway(animated: Bool = true) {
        let id = UUID(); transition = id
        edgeHidden = edgeHide; hover.reset()
        // Release the editor before hiding, so the next edge reveal does not retain stale focus.
        makeFirstResponder(nil)
        guard animated && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil); alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == id else { return }
                self.orderOut(nil); self.alphaValue = 1
            }
        }
    }

    /// Automatic answers should not interrupt the user's chosen tucked-away state.
    func showForAnswer(automatic: Bool = true) { if !automatic || !edgeHide { reveal() } }

    func stopWatching() {
        edgeTimer?.invalidate(); edgeTimer = nil
        geometryTask?.cancel(); geometryTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
    }
    override func close() { stopWatching(); super.close() }

    func toggleVisibility() {
        if isVisible && !edgeHidden { tuckAway() } else { reveal() }
    }
}
