import AppKit
import Darwin
import ObjectiveC.runtime

/// Per-window capture preference. Its effect must be verified in the meeting client.
/// The private region backend is retained only for explicit diagnostic injection:
/// it made the installed SwiftUI overlay gray locally during Tencent sharing.
/// Normal application startup must never select that backend automatically.
@MainActor
final class WindowCaptureProtection {
    enum Status: Equatable {
        case disabled, legacyRequested, applied, failed(Int32)
    }

    struct Backend {
        let setRegion: (Int, CGRect?) -> Int32

        static func system() -> Backend? {
            typealias Connection = @convention(c) () -> UInt32
            typealias Create = @convention(c) (CGRect) -> Unmanaged<CFTypeRef>?
            typealias Apply = @convention(c) (UInt32, Int, CFTypeRef?) -> Int32
            let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
            guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
                  let createSymbol = dlsym(handle, "CGRegionCreateWithRect"),
                  let applySymbol = dlsym(handle, "CGSSetWindowCaptureExcludeShape") else { return nil }
            let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
            let create = unsafeBitCast(createSymbol, to: Create.self)
            let apply = unsafeBitCast(applySymbol, to: Apply.self)
            return Backend { windowID, rect in
                guard let rect else { return apply(connection(), windowID, nil) }
                guard let region = create(rect)?.takeRetainedValue() else { return CGError.failure.rawValue }
                return withExtendedLifetime(region) { apply(connection(), windowID, region) }
            }
        }
    }

    private let backend: Backend?
    private(set) var status: Status = .disabled
    init(backend: Backend? = nil) { self.backend = backend }

    @discardableResult
    func apply(to window: NSWindow, enabled: Bool, covering size: CGSize? = nil) -> Status {
        // Changing the legacy flag also changes WindowServer capture state.
        // Geometry refreshes must not keep resetting an unchanged flag while
        // a conference client is actively consuming that window's surfaces.
        let sharing: NSWindow.SharingType = enabled ? .none : .readOnly
        if window.sharingType != sharing { window.sharingType = sharing }
        guard let backend else {
            // Requested is deliberately not a claim of verified capture exclusion.
            status = enabled ? .legacyRequested : .disabled
            return status
        }
        let size = size ?? window.frame.size
        guard window.windowNumber > 0, size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else {
            status = .failed(CGError.illegalArgument.rawValue)
            return status
        }
        // Window coordinates are points, with a zero origin (not screen pixels).
        let rect = enabled ? CGRect(origin: .zero, size: size) : nil
        let result = backend.setRegion(window.windowNumber, rect)
        status = result == CGError.success.rawValue ? (enabled ? .applied : .disabled) : .failed(result)
        return status
    }
}

/// InputMethodKit hosts its candidate surface in a separate ViewBridge panel.
/// Protect only app-owned input panels while editing the protected overlay;
/// never change another process's windows or blanket-protect settings/setup.
@MainActor
final class OverlayInputCaptureProtection {
    private struct SavedWindow {
        weak var window: NSWindow?
        let sharing: NSWindow.SharingType
    }
    private weak var overlay: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var saved: [ObjectIdentifier: SavedWindow] = [:]
    private var enabled = true
    private let candidate: @MainActor (NSWindow) -> Bool

    init(overlay: NSWindow, candidate: @escaping @MainActor (NSWindow) -> Bool = isInputPanel) {
        self.overlay = overlay
        self.candidate = candidate
        InputPanelOrdering.add(self)
        let center = NotificationCenter.default
        for name in [NSApplication.willUpdateNotification, NSApplication.didUpdateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    static func isInputPanel(_ window: NSWindow) -> Bool {
        // Observed on the supported host: a separate NSPanel with NSRemoteView,
        // not a child window. Keep this narrow; unknown future classes are not
        // permission to alter arbitrary panels or the user's system input method.
        NSStringFromClass(type(of: window)) == "NSPanel.ViewBridge.rendezvous" &&
            window.contentView.map { NSStringFromClass(type(of: $0)) == "NSRemoteView" } == true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { refresh() } else { restoreAll() }
    }

    private var protectsEditing: Bool {
        enabled && overlay?.isKeyWindow == true &&
            (overlay?.firstResponder as? NSTextView)?.isEditable == true
    }

    func refresh() {
        update(windows: NSApp.windows, protectInput: protectsEditing)
    }

    fileprivate func willOrder(_ window: NSWindow) {
        guard window !== overlay, candidate(window) else { return }
        if protectsEditing {
            protect(window)
        } else {
            // A reused panel is about to be presented for an ordinary input
            // owner. Restore before that presentation, not at focus loss while
            // its previous protected content is still on screen.
            restore(ObjectIdentifier(window))
        }
    }

    fileprivate func didOrderOut(_ window: NSWindow) {
        if !protectsEditing && !window.isVisible { restore(ObjectIdentifier(window)) }
    }

    // Explicit inputs make focus changes and reuse testable without an IME or
    // synthesizing keystrokes. Production callers use refresh() above.
    func update(windows: [NSWindow], protectInput: Bool) {
        let targets = protectInput ? windows.filter { $0 !== overlay && candidate($0) } : []
        let targetIDs = Set(targets.map(ObjectIdentifier.init))
        for (id, entry) in saved where !targetIDs.contains(id) {
            // InputMethodKit may retire a candidate panel asynchronously after
            // the field loses focus. Making that still-visible panel shareable
            // can expose a frame, as seen in the synthetic focus-loss probe.
            if entry.window?.isVisible != true { restore(id) }
        }
        targets.forEach(protect)
    }

    private func protect(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if saved[id] == nil { saved[id] = SavedWindow(window: window, sharing: window.sharingType) }
        if window.sharingType != .none { window.sharingType = .none }
    }

    private func restore(_ id: ObjectIdentifier) {
        guard let entry = saved.removeValue(forKey: id) else { return }
        if let window = entry.window, window.sharingType != entry.sharing {
            window.sharingType = entry.sharing
        }
    }

    private func restoreAll() {
        for id in Array(saved.keys) { restore(id) }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        InputPanelOrdering.remove(self)
        // Closing the overlay also ends its input session. Withdraw any old
        // candidate before restoring its sharing flag, avoiding a final flash.
        for entry in Array(saved.values) where entry.window?.isVisible == true {
            entry.window?.orderOut(nil)
        }
        restoreAll()
    }
}

/// Application update notifications arrive after a new ViewBridge panel can
/// already be on screen. Interpose the public AppKit ordering entry points once
/// in this process so the narrowly matched input panel is protected BEFORE its
/// first presentation. All other windows forward unchanged, and no code runs in
/// another process. Weak registrations keep closed overlays out of the hook.
@MainActor
private enum InputPanelOrdering {
    private struct WeakController { weak var value: OverlayInputCaptureProtection? }
    private static var controllers: [WeakController] = []
    private static let install: Void = {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.lc_inputOrder(_:relativeTo:))),
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.lc_inputOrderFrontRegardless))
        ]
        for (original, replacement) in pairs {
            guard let first = class_getInstanceMethod(NSWindow.self, original),
                  let second = class_getInstanceMethod(NSWindow.self, replacement) else { continue }
            method_exchangeImplementations(first, second)
        }
    }()

    static func add(_ controller: OverlayInputCaptureProtection) {
        _ = install
        controllers.removeAll { $0.value == nil }
        controllers.append(WeakController(value: controller))
    }

    static func remove(_ controller: OverlayInputCaptureProtection) {
        controllers.removeAll { $0.value == nil || $0.value === controller }
    }

    static func willOrder(_ window: NSWindow) {
        controllers.forEach { $0.value?.willOrder(window) }
    }

    static func didOrderOut(_ window: NSWindow) {
        controllers.forEach { $0.value?.didOrderOut(window) }
    }
}

private extension NSWindow {
    @objc func lc_inputOrder(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { InputPanelOrdering.willOrder(self) }
        // The exchanged selector calls AppKit's original implementation.
        lc_inputOrder(place, relativeTo: otherWin)
        if place == .out { InputPanelOrdering.didOrderOut(self) }
    }

    @objc func lc_inputOrderFrontRegardless() {
        InputPanelOrdering.willOrder(self)
        lc_inputOrderFrontRegardless()
    }
}

/// A recorder can capture the system pointer independently of excluded windows.
/// Normalize only this app's text-pointer requests over a protected overlay.
/// The insertion caret, selection, keyboard input and resize cursors are untouched.
@MainActor
final class OverlayCursorProtection {
    private weak var window: NSWindow?
    private var enabled = true
    private let pointer: @MainActor () -> NSPoint
    private let topWindow: @MainActor (NSPoint) -> Int

    init(window: NSWindow,
         pointer: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
         topWindow: @escaping @MainActor (NSPoint) -> Int = {
             NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0)
         }) {
        self.window = window; self.pointer = pointer; self.topWindow = topWindow
        TextPointerRequests.add(self)
        window.resetCursorRects()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        window?.resetCursorRects()
        if replaces(NSCursor.current) { NSCursor.arrow.set() }
    }

    fileprivate func replaces(_ cursor: NSCursor, in owner: NSWindow?) -> Bool {
        enabled && owner != nil && owner === window &&
            (cursor === NSCursor.iBeam || cursor === NSCursor.iBeamCursorForVerticalLayout)
    }

    fileprivate func replaces(_ cursor: NSCursor) -> Bool {
        guard enabled, cursor === NSCursor.iBeam || cursor === NSCursor.iBeamCursorForVerticalLayout,
              let window, window.isVisible, window.alphaValue > 0 else { return false }
        let point = pointer()
        // Bounds alone would also match a settings/other-app window lying above
        // the overlay. Require the actual topmost window at the pointer.
        return window.frame.contains(point) && topWindow(point) == window.windowNumber
    }

    func stop() {
        TextPointerRequests.remove(self)
        window?.resetCursorRects()
    }
}

@MainActor
private enum TextPointerRequests {
    private struct WeakController { weak var value: OverlayCursorProtection? }
    private static var controllers: [WeakController] = []
    private static let install: Void = {
        for (original, replacement) in [
            (#selector(NSCursor.set), #selector(NSCursor.lc_overlaySet)),
            (#selector(NSCursor.push), #selector(NSCursor.lc_overlayPush))
        ] {
            guard let first = class_getInstanceMethod(NSCursor.self, original),
                  let second = class_getInstanceMethod(NSCursor.self, replacement) else { continue }
            method_exchangeImplementations(first, second)
        }
        if let first = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:))),
           let second = class_getInstanceMethod(NSView.self, #selector(NSView.lc_overlayAddCursorRect(_:cursor:))) {
            method_exchangeImplementations(first, second)
        }
    }()

    static func add(_ controller: OverlayCursorProtection) {
        _ = install
        controllers.removeAll { $0.value == nil }
        controllers.append(WeakController(value: controller))
    }
    static func remove(_ controller: OverlayCursorProtection) {
        controllers.removeAll { $0.value == nil || $0.value === controller }
    }
    static func replaces(_ cursor: NSCursor) -> Bool {
        controllers.contains { $0.value?.replaces(cursor) == true }
    }
    static func replaces(_ cursor: NSCursor, in window: NSWindow?) -> Bool {
        controllers.contains { $0.value?.replaces(cursor, in: window) == true }
    }
}

private extension NSView {
    @objc func lc_overlayAddCursorRect(_ rect: NSRect, cursor: NSCursor) {
        // Store the final pointer in AppKit's tracking rectangle, rather than
        // correcting the pointer after the mouse has already entered it.
        let replacement = TextPointerRequests.replaces(cursor, in: window) ? NSCursor.arrow : cursor
        lc_overlayAddCursorRect(rect, cursor: replacement)
    }
}

private extension NSCursor {
    @objc func lc_overlaySet() {
        // Invoke the exchanged original with the final cursor, so no I-beam is
        // briefly displayed before being corrected on a later event or timer.
        guard Thread.isMainThread else { lc_overlaySet(); return }
        let replace = MainActor.assumeIsolated { TextPointerRequests.replaces(self) }
        (replace ? NSCursor.arrow : self).lc_overlaySet()
    }
    @objc func lc_overlayPush() {
        // Preserve the number of stack pushes/pops used by AppKit tracking.
        guard Thread.isMainThread else { lc_overlayPush(); return }
        let replace = MainActor.assumeIsolated { TextPointerRequests.replaces(self) }
        (replace ? NSCursor.arrow : self).lc_overlayPush()
    }
}
