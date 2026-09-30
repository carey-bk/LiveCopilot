import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A click-to-record shortcut field. While "listening", the next key press
/// (with at least one modifier) is captured as a `HotkeyCombo`.
struct KeyRecorderView: NSViewRepresentable {
    let combo: HotkeyCombo
    var language: AppLanguage = .system
    var onRecordingChanged: ((Bool) -> Void)?
    let onRecorded: (HotkeyCombo) -> Bool

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.language = language
        view.onRecorded = onRecorded
        view.onRecordingChanged = onRecordingChanged
        view.combo = combo
        return view
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.language = language
        nsView.onRecorded = onRecorded
        nsView.onRecordingChanged = onRecordingChanged
        if !nsView.isRecording { nsView.combo = combo }
    }

    static func dismantleNSView(_ nsView: RecorderButton, coordinator: ()) { nsView.stopRecording() }
}

/// An `NSButton` that, when clicked, becomes first responder and captures the
/// next modified key press as the new shortcut.
final class RecorderButton: NSButton {
    var onRecorded: ((HotkeyCombo) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?
    var language = AppLanguage.system { didSet { refreshTitle() } }
    var combo: HotkeyCombo? { didSet { refreshTitle() } }
    private(set) var isRecording = false {
        didSet { refreshTitle() }
    }

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .roundRect
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            self?.stopRecording()
        }
        // Local monitor: capture the next key down while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            stopRecording()
            return event
        }
        // Escape cancels recording without changing anything.
        if event.type == .keyDown && Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return nil
        }
        guard event.type == .keyDown else { return event } // ignore bare modifier changes
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Require at least one modifier so the shortcut is safe as a global hotkey.
        guard !mods.isEmpty else { return nil }

        let carbon = HotkeyCombo.carbonModifiers(from: mods)
        let recorded = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon)
        if onRecorded?(recorded) == true { combo = recorded }
        stopRecording()
        return nil
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onRecordingChanged?(false)
    }

    private func refreshTitle() {
        title = isRecording ? L10n.text("Press keys…", language: language) : (combo?.display ?? L10n.text("Record", language: language))
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
