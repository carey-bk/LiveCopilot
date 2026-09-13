import Foundation
import Combine
import Carbon.HIToolbox
import AppKit

/// A global hotkey: a key code plus Carbon modifier flags.
struct HotkeyCombo: Codable, Equatable {
    /// Virtual key code (e.g. `kVK_Space`).
    let keyCode: UInt32
    /// Carbon modifier mask (`optionKey`, `cmdKey`, `controlKey`, `shiftKey`).
    let modifiers: UInt32

    /// Human-readable glyphs, e.g. "⌥Space", "⌃⇧R".
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += HotkeyCombo.keyName(for: keyCode)
        return s
    }

    /// Convert AppKit `NSEvent.modifierFlags` into a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// A friendly name for the non-modifier key.
    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            // Map letter/number key codes to their character via the current layout.
            if let ch = Self.character(for: keyCode) { return ch.uppercased() }
            return "key\(keyCode)"
        }
    }

    /// Look up the character produced by a virtual key code on the active layout.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { ptr -> OSStatus in
            guard let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// Persisted, observable hotkey assignments. One combo per suggestion mode plus
/// the fixed overlay-toggle (not user-editable). Stored in `UserDefaults`.
@MainActor
final class HotkeyStore: ObservableObject {
    @Published private(set) var combos: [SuggestionMode: HotkeyCombo]

    /// Fixed (non-adjustable) overlay show/hide hotkey: ⌥H.
    let toggleOverlay = HotkeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey))

    private let defaults: UserDefaults
    private static let storageKey = "hotkeyCombos.v1"

    static let defaultCombos: [SuggestionMode: HotkeyCombo] = [
        .reply:    HotkeyCombo(keyCode: UInt32(kVK_Space),  modifiers: UInt32(optionKey)),
        .recap:    HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey)),
        .followUp: HotkeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey)),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: HotkeyCombo].self, from: data) {
            var map: [SuggestionMode: HotkeyCombo] = [:]
            for (key, value) in decoded {
                if let mode = SuggestionMode(rawValue: key) { map[mode] = value }
            }
            // Backfill any missing modes from defaults.
            combos = Self.defaultCombos.merging(map) { _, persisted in persisted }
        } else {
            combos = Self.defaultCombos
        }
    }

    func combo(for mode: SuggestionMode) -> HotkeyCombo {
        combos[mode] ?? Self.defaultCombos[mode]!
    }

    /// Update one mode's combo and persist (immutably).
    func set(_ combo: HotkeyCombo, for mode: SuggestionMode) {
        combos = combos.merging([mode: combo]) { _, new in new }
        persist()
    }

    func reset(_ mode: SuggestionMode) {
        set(Self.defaultCombos[mode]!, for: mode)
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
