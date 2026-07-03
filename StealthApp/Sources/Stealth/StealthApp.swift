import SwiftUI
import AppKit

@main
struct StealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar only — no dock icon (LSUIElement in Info.plist).
        MenuBarExtra("Stealth", systemImage: appDelegate.coordinator.isRunning ? "waveform" : "waveform.slash") {
            MenuContent(coordinator: appDelegate.coordinator,
                        openSettings: appDelegate.openSettings,
                        openHistory: appDelegate.openHistory,
                        toggleOverlay: appDelegate.toggleOverlay)
        }
    }
}

/// The menu-bar dropdown.
private struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    let openSettings: () -> Void
    let openHistory: () -> Void
    let toggleOverlay: () -> Void

    var body: some View {
        Text(coordinator.statusMessage)
            .font(.caption)

        Button(coordinator.isRunning ? "Stop Listening" : "Start Listening") {
            Task { await coordinator.toggle() }
        }
        .disabled(!coordinator.hasAPIKey)

        Button("Suggest Reply (\(coordinator.hotkeys.combo(for: .reply).display))") {
            coordinator.requestSuggestion(mode: .reply)
        }
        .disabled(!coordinator.isRunning)

        Button(coordinator.micEnabled ? "Mute Mic (You)" : "Unmute Mic (You)") {
            coordinator.toggleMic()
        }

        Button("Show / Hide Overlay (⌥H)") { toggleOverlay() }

        Divider()

        Button("History…") { openHistory() }
        Button("Settings…") { openSettings() }
        Button("Quit Stealth") { NSApp.terminate(nil) }

        Divider()

        Text(AppInfo.display)
            .font(.caption2)
    }
}

/// Owns the overlay window, hotkeys, and settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt-and-braces: no dock icon

        let overlay = OverlayWindow(rootView: OverlayView(coordinator: coordinator))
        overlay.orderFrontRegardless()
        self.overlay = overlay

        hotkeys.register(
            store: coordinator.hotkeys,
            onSuggest: { [weak self] mode in self?.coordinator.requestSuggestion(mode: mode) },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() }
        )
        // Rebind live whenever Settings records a new shortcut.
        coordinator.onHotkeysChanged = { [weak self] in self?.hotkeys.reload() }

        // If there's no key yet, surface settings so the user can paste one.
        if !coordinator.hasAPIKey { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        Task { await coordinator.stop() }
    }

    func toggleOverlay() {
        overlay?.toggleVisibility()
    }

    func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stealth"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    func openHistory() {
        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HistoryView(store: coordinator.sessions))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stealth — History"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }
}
