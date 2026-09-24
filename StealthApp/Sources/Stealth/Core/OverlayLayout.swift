import Foundation

/// Screen coordinates are AppKit points, including negative origins on secondary displays.
enum OverlayLayout {
    /// Only content panes consume spare height; never put window controls in a
    /// scrolled or oversized hosting view. Header/footer measurements are fixed.
    static func panes(available: CGFloat, transcriptIdeal: CGFloat, answerIdeal: CGFloat, automatic: Bool) -> (transcript: CGFloat, answer: CGFloat) {
        let room = max(0, available)
        // Give captions their measured height before allocating the answer pane.
        // The old 45% cap clipped even a single line when the window had fitted
        // itself to exactly transcriptIdeal + the 28-point empty answer.
        let transcript = min(transcriptIdeal, max(0, room - 28))
        let answer = automatic ? min(max(28, answerIdeal), max(0, room - transcript)) : max(0, room - transcript)
        return (transcript, answer)
    }
    static func fitted(_ frame: CGRect, height: CGFloat, visible: CGRect, docked: Bool) -> CGRect {
        let inset = visible.insetBy(dx: 12, dy: 12)
        let width = min(frame.width, inset.width)
        let height = min(max(240, height), inset.height, 900)
        let x = docked ? inset.maxX - width : min(max(frame.minX, inset.minX), inset.maxX - width)
        let top = min(max(frame.maxY, inset.minY + height), inset.maxY)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
    static func atRightEdge(_ point: CGPoint, screen: CGRect, visible: CGRect) -> Bool {
        // Do not capture the menu-bar or Dock corners; no keyboard/mouse event interception.
        point.x >= screen.maxX - 3 && point.x <= screen.maxX &&
        point.y >= visible.minY + 12 && point.y <= visible.maxY - 12
    }
}

/// Dwell and leave delays prevent flicker while crossing the edge or selecting text.
struct OverlayHoverState {
    private var edgeSince: TimeInterval?
    private var outsideSince: TimeInterval?
    mutating func reset() { edgeSince = nil; outsideSince = nil }
    mutating func shouldReveal(atEdge: Bool, now: TimeInterval) -> Bool {
        guard atEdge else { edgeSince = nil; return false }
        if edgeSince == nil { edgeSince = now }
        return now - edgeSince! >= 0.16
    }
    mutating func shouldHide(inside: Bool, interacting: Bool, now: TimeInterval) -> Bool {
        guard !inside && !interacting else { outsideSince = nil; return false }
        if outsideSince == nil { outsideSince = now }
        return now - outsideSince! >= 0.9
    }
}
