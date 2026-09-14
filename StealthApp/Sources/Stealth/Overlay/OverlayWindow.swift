import AppKit
import SwiftUI

/// A floating, always-on-top panel that requests exclusion from screen capture.
///
/// The stealth properties:
///  - `sharingType = .none` requests exclusion; verify in the actual sharing app.
///  - `.floating` level + joins all Spaces → stays above fullscreen calls.
///  - non-activating panel → clicking it never steals focus from the meeting.
final class OverlayWindow: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Resize bounds.
        minSize = NSSize(width: 400, height: 440)
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

        contentView = OverlayResizeView(content: NSHostingView(rootView: rootView))

        positionTopRight()
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

    func toggleVisibility() {
        if isVisible {
            orderOut(nil)
        } else {
            orderFrontRegardless()
        }
    }
}
