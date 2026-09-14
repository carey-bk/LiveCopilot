import SwiftUI
import AppKit
import Combine

@main
struct LiveCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep the menu-bar controls alongside the normal Dock application.
        MenuBarExtra("LiveCopilot", systemImage: appDelegate.coordinator.isRunning ? "waveform" : "waveform.slash") {
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

    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        Text(t(coordinator.statusMessage))
            .font(.caption)

        Button(t(coordinator.isRunning ? "Stop Listening" : "Start Listening")) {
            Task { await coordinator.toggle() }
        }
        .disabled(coordinator.isTransitioning)

        Button("\(t("Suggest Reply")) (\(coordinator.hotkeys.combo(for: .reply).display))") {
            coordinator.requestSuggestion(mode: .reply)
        }
        .disabled(coordinator.transcript.lines.isEmpty)

        Button(t(coordinator.micEnabled ? "Mute Mic (You)" : "Unmute Mic (You)")) {
            coordinator.toggleMic()
        }

        Button(t("Show / Hide Overlay (⌥H)")) { toggleOverlay() }

        Divider()

        Button(t("History…")) { openHistory() }
        Button(t("Settings…")) { openSettings() }
        Button(t("Quit LiveCopilot")) { NSApp.terminate(nil) }

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
    private var terminationSignal: DispatchSourceSignal?
    private var terminationInProgress = false
    private var readyToTerminate = false
    private var settingsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        NSApp.setActivationPolicy(.regular)

        let overlay = OverlayWindow(rootView: OverlayView(coordinator: coordinator, onContentHeight: { [weak self] height in
            // Hosting can measure synchronously inside OverlayWindow.init, before self.overlay is assigned.
            DispatchQueue.main.async { self?.overlay?.contentHeightChanged(height) }
        }))
        overlay.orderFrontRegardless()
        self.overlay = overlay
        overlay.onManualHeight = { [weak self] in self?.coordinator.settings.overlayAutoHeight = false }
        settingsObservation = coordinator.$settings.sink { [weak self] settings in self?.applyPreferences(settings) }
        coordinator.onOpenSettings = { [weak self] in self?.openSettings() }
        coordinator.onShowOverlay = { [weak self] automatic in self?.overlay?.showForAnswer(automatic: automatic) }

        hotkeys.onError = { [weak self] message in self?.coordinator.statusMessage = message }
        hotkeys.register(
            store: coordinator.hotkeys,
            onSuggest: { [weak self] mode in self?.coordinator.requestSuggestion(mode: mode) },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() }
        )
        // Rebind live whenever Settings records a new shortcut.
        coordinator.onHotkeysChanged = { [weak self] in self?.hotkeys.reload() }

        // If there's no key yet, surface settings so the user can paste one.
        if coordinator.settings.requiresOpenAIKey && !coordinator.hasAPIKey { openSettings() }
    }

    private func applyPreferences(_ settings: AppSettings) {
        for window in [overlay, settingsWindow, historyWindow].compactMap({ $0 }) {
            applyAppearance(to: window, background: settings.background)
            if !(window is OverlayWindow) { window.sharingType = .readOnly }
        }
        let preview = coordinator.isMock && ProcessInfo.processInfo.arguments.contains("--ui-preview")
        overlay?.sharingType = settings.excludeOverlayFromCapture && !preview ? .none : .readOnly
        overlay?.configure(autoHeight: settings.overlayAutoHeight, edgeHide: settings.overlayEdgeHide)
        if let menu = NSApp.mainMenu { localizeMenu(menu, language: settings.language) }
        settingsWindow?.title = L10n.text("LiveCopilot Settings", language: settings.language)
        historyWindow?.title = L10n.text("LiveCopilot — History", language: settings.language)
    }

    private func applyAppearance(to window: NSWindow, background: AppBackground) {
        window.appearance = background.usesLightAppearance ? NSAppearance(named: .aqua) : nil
        if !(window is OverlayWindow) {
            window.isOpaque = background != .frosted
            window.backgroundColor = background == .frosted ? .clear : .windowBackgroundColor
        }
    }

    private func localizeMenu(_ menu: NSMenu, language: AppLanguage) {
        for item in menu.items {
            let standard = ["Edit", "View", "Window", "Help", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Close Window", "Minimize", "Zoom", "Bring All to Front", "Hide LiveCopilot", "Hide Others", "Show All", "About LiveCopilot"]
            if let original = standard.first(where: { item.title == $0 || item.title == L10n.chinese[$0] }) {
                item.title = L10n.text(original, language: language)
            }
            if let submenu = item.submenu { localizeMenu(submenu, language: language) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        guard !terminationInProgress else { return .terminateCancel }
        terminationInProgress = true
        Task {
            await coordinator.shutdown()
            readyToTerminate = true
            sender.terminate(nil)
        }
        // Keep the normal event loop running while asynchronous Live close events
        // arrive. AppKit's terminateLater loop can starve MainActor cleanup tasks.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stopWatching()
        hotkeys.unregisterAll()
        coordinator.saveSession()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay?.reveal()
        overlay?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func toggleOverlay() {
        overlay?.toggleVisibility()
        DebugLog.log("overlay.visibility visible=\(overlay?.isVisible == true)")
    }

    func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.text("LiveCopilot Settings", language: coordinator.settings.language)
        window.sharingType = .readOnly
        applyAppearance(to: window, background: coordinator.settings.background)
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 820, height: 640)
        window.setContentSize(NSSize(width: 860, height: 680))
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
        let hosting = NSHostingController(rootView: HistoryView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.text("LiveCopilot — History", language: coordinator.settings.language)
        window.sharingType = .readOnly
        applyAppearance(to: window, background: coordinator.settings.background)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }
}
