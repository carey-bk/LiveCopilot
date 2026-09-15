import AppKit

/// An in-window 12 pt border and 28 pt corners make borderless panels easy to grab.
/// The content keeps its normal hit testing everywhere else, including text selection.
final class OverlayResizeView: NSView {
    struct Edge: OptionSet {
        let rawValue: Int
        static let left = Self(rawValue: 1), right = Self(rawValue: 2)
        static let bottom = Self(rawValue: 4), top = Self(rawValue: 8)
    }
    static let border: CGFloat = 12
    static let corner: CGFloat = 28

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func edges(at point: NSPoint) -> Edge {
        guard bounds.contains(point) else { return [] }
        let left = point.x < Self.corner, right = point.x > bounds.maxX - Self.corner
        let bottom = point.y < Self.corner, top = point.y > bounds.maxY - Self.corner
        if (left || right) && (bottom || top) {
            return (left ? Edge.left : .right).union(bottom ? .bottom : .top)
        }
        if point.x < Self.border { return .left }
        if point.x > bounds.maxX - Self.border { return .right }
        if point.y < Self.border { return .bottom }
        if point.y > bounds.maxY - Self.border { return .top }
        return []
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !edges(at: local).isEmpty { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        let b = Self.border, c = Self.corner, w = bounds.width, h = bounds.height
        addCursorRect(NSRect(x: 0, y: c, width: b, height: h - 2*c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w-b, y: c, width: b, height: h - 2*c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: c, y: 0, width: w - 2*c, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: h-b, width: w - 2*c, height: b), cursor: .resizeUpDown)
        for (x, y, symbol) in [(CGFloat(0), CGFloat(0), "arrow.up.right.and.arrow.down.left"),
                                (w-c, h-c, "arrow.up.right.and.arrow.down.left"),
                                (CGFloat(0), h-c, "arrow.up.left.and.arrow.down.right"),
                                (w-c, CGFloat(0), "arrow.up.left.and.arrow.down.right")] {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            let cursor = NSCursor(image: image, hotSpot: NSPoint(x: image.size.width/2, y: image.size.height/2))
            addCursorRect(NSRect(x: x, y: y, width: c, height: c), cursor: cursor)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edge = edges(at: convert(event.locationInWindow, from: nil))
        guard !edge.isEmpty else { super.mouseDown(with: event); return }
        let original = window.frame, start = NSEvent.mouseLocation
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let frame = Self.resized(original, by: NSPoint(x: current.x-start.x, y: current.y-start.y),
                                     edges: edge, minimum: window.minSize, maximum: window.maxSize)
            window.setFrame(frame, display: true)
        }
        window.invalidateCursorRects(for: self)
        (window as? OverlayWindow)?.userFinishedResize(vertical: edge.contains(.top) || edge.contains(.bottom))
    }
    static func resized(_ frame: NSRect, by delta: NSPoint, edges: Edge, minimum: NSSize, maximum: NSSize) -> NSRect {
        var result = frame
        if edges.contains(.left) || edges.contains(.right) {
            result.size.width = min(max(frame.width + (edges.contains(.left) ? -delta.x : delta.x), minimum.width), maximum.width)
            if edges.contains(.left) { result.origin.x = frame.maxX - result.width }
        }
        if edges.contains(.bottom) || edges.contains(.top) {
            result.size.height = min(max(frame.height + (edges.contains(.bottom) ? -delta.y : delta.y), minimum.height), maximum.height)
            if edges.contains(.bottom) { result.origin.y = frame.maxY - result.height }
        }
        return result
    }
}
