import AppKit
import Carbon.HIToolbox

/// Registers global (system-wide) hotkeys using the Carbon Hot Key API.
/// Carbon is the only reliable way to get true global hotkeys without Accessibility
/// permission, and it works even when our app is not focused (it never is — the call is).
///
/// Defaults:
///   ⌥Space → suggest a reply        (adjustable in Settings)
///   ⌥R     → recap the conversation (adjustable in Settings)
///   ⌥F     → follow-up question     (adjustable in Settings)
///   ⌥H     → show / hide the overlay (fixed)
@MainActor
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    // Stable hotkey IDs.
    private enum ID {
        static let reply: UInt32 = 1
        static let toggleOverlay: UInt32 = 2
        static let recap: UInt32 = 3
        static let followUp: UInt32 = 4
    }

    private func id(for mode: SuggestionMode) -> UInt32 {
        switch mode {
        case .reply: return ID.reply
        case .recap: return ID.recap
        case .followUp: return ID.followUp
        }
    }

    private let signature: OSType = {
        // 'STLH'
        let chars: [UInt8] = [0x53, 0x54, 0x4C, 0x48]
        return chars.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var store: HotkeyStore?
    private var onSuggest: ((SuggestionMode) -> Void)?
    private var onToggleOverlay: (() -> Void)?

    /// Register all hotkeys from the store. Safe to call again to rebind live.
    func register(store: HotkeyStore,
                  onSuggest: @escaping (SuggestionMode) -> Void,
                  onToggleOverlay: @escaping () -> Void) {
        self.store = store
        self.onSuggest = onSuggest
        self.onToggleOverlay = onToggleOverlay
        rebuild()
    }

    /// Re-read the store and re-register every hotkey (e.g. after the user
    /// records a new shortcut in Settings).
    func reload() {
        rebuild()
    }

    private func rebuild() {
        guard let store, let onSuggest, let onToggleOverlay else { return }
        unregisterAll()
        installDispatcher()

        for mode in SuggestionMode.allCases {
            let combo = store.combo(for: mode)
            add(id: id(for: mode), keyCode: combo.keyCode, modifiers: combo.modifiers) {
                onSuggest(mode)
            }
        }
        // Fixed overlay toggle.
        add(id: ID.toggleOverlay,
            keyCode: store.toggleOverlay.keyCode,
            modifiers: store.toggleOverlay.modifiers,
            action: onToggleOverlay)
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        handlers.removeAll()
    }

    private func add(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr { refs.append(ref) }
    }

    private func installDispatcher() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let hkID = hotKeyID.id
                DispatchQueue.main.async {
                    if let action = manager.handlers[hkID] { action() }
                }
                return noErr
            },
            1, &spec, selfPtr, &eventHandler
        )
    }
}
