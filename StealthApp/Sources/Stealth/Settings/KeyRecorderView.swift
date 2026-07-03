import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A click-to-record shortcut field. While "listening", the next key press
/// (with at least one modifier) is captured as a `HotkeyCombo`.
struct KeyRecorderView: NSViewRepresentable {
    let combo: HotkeyCombo
    let onRecorded: (HotkeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onRecorded = onRecorded
        view.combo = combo
        return view
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecorded = onRecorded
        if !nsView.isRecording { nsView.combo = combo }
    }
}

/// An `NSButton` that, when clicked, becomes first responder and captures the
/// next modified key press as the new shortcut.
final class RecorderButton: NSButton {
    var onRecorded: ((HotkeyCombo) -> Void)?
    var combo: HotkeyCombo? { didSet { refreshTitle() } }
    private(set) var isRecording = false {
        didSet { refreshTitle() }
    }

    private var monitor: Any?

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
        // Local monitor: capture the next key down while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
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
        combo = recorded
        onRecorded?(recorded)
        stopRecording()
        return nil
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func refreshTitle() {
        title = isRecording ? "Press keys…" : (combo?.display ?? "Record")
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
