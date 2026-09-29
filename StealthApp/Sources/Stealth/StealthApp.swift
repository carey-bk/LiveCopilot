import SwiftUI
import AppKit
import Combine

@main
struct LiveCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep the menu-bar controls alongside the normal Dock application.
        MenuBarExtra("LiveCopilot", systemImage: appDelegate.coordinator.isRunning ? "waveform" : "waveform.slash") {
            MenuContent(coordinator: appDelegate.coordinator, hotkeys: appDelegate.coordinator.hotkeys,
                        openSettings: appDelegate.openSettings,
                        openHistory: appDelegate.openHistory,
                        toggleOverlay: appDelegate.toggleOverlay)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: appDelegate.coordinator.updates, language: appDelegate.coordinator.settings.language)
            }
        }
    }
}

/// The menu-bar dropdown.
private struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
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

        Button("\(t(SuggestionMode.reply.label)) (\(hotkeys.combo(for: .reply).display))") {
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
        CheckForUpdatesButton(updates: coordinator.updates, language: coordinator.settings.language)
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
    private var onboardingWindow: NSWindow?
    private var terminationSignal: DispatchSourceSignal?
    private var terminationInProgress = false
    private var readyToTerminate = false
    private var settingsObservation: AnyCancellable?
    private var onboardingObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        NSApp.setActivationPolicy(.regular)
        coordinator.updates.blockingReason = { [weak self] in
            guard let self else { return nil }
            let c = self.coordinator
            guard c.isRunning || c.isTransitioning || c.isIndexing || c.localModels.downloading != nil || c.laya.isBusy || c.appleSpeech.busy else { return nil }
            return ServiceGuide.text("Finish listening, indexing, or preparing models before checking for updates.",
                                     "请先结束监听、资料索引或模型准备，再检查更新。", c.settings.language)
        }
        coordinator.updates.prepareForRelaunch = { [weak self] in
            guard let self else { return }
            await self.coordinator.shutdown()
            self.coordinator.saveSession()
            self.readyToTerminate = true
        }
        coordinator.updates.start()
        if AppPaths.isOnboardingPreview && ProcessInfo.processInfo.arguments.contains("--onboarding-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let overlay = OverlayWindow(rootView: OverlayView(coordinator: coordinator, onContentHeight: { [weak self] height in
            // Hosting can measure synchronously inside OverlayWindow.init, before self.overlay is assigned.
            DispatchQueue.main.async { self?.overlay?.contentHeightChanged(height) }
        }, onMinimumHeight: { [weak self] height in
            DispatchQueue.main.async { self?.overlay?.minimumContentHeightChanged(height) }
        }))
        if !coordinator.onboarding.state.shouldPresent || coordinator.isMock {
            coordinator.onboarding.enterOverlay()
            overlay.orderFrontRegardless()
        }
        self.overlay = overlay
        if AppPaths.isOnboardingPreview && ProcessInfo.processInfo.arguments.contains("--onboarding-compact") {
            overlay.setContentSize(NSSize(width: 400, height: 280))
        }
        overlay.onManualHeight = { [weak self] in self?.coordinator.settings.overlayAutoHeight = false }
        settingsObservation = coordinator.$settings.sink { [weak self] settings in self?.applyPreferences(settings) }
        coordinator.onOpenSettings = { [weak self] in self?.openSettings() }
        coordinator.onOpenOnboarding = { [weak self] in self?.openOnboarding() }
        coordinator.onShowOverlayTips = { [weak self] in
            guard let self else { return }
            self.closeOnboarding(); self.settingsWindow?.orderOut(nil)
            self.coordinator.onboarding.replayTips()
            self.syncGuidancePresentation()
            self.overlay?.makeKeyAndOrderFront(nil)
        }
        onboardingObservation = coordinator.onboarding.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncGuidancePresentation() }
        }
        syncGuidancePresentation()
        coordinator.onShowOverlay = { [weak self] automatic in self?.overlay?.showForAnswer(automatic: automatic) }

        hotkeys.onError = { [weak self] message in self?.coordinator.statusMessage = message }
        hotkeys.register(
            store: coordinator.hotkeys,
            onSuggest: { [weak self] mode in self?.coordinator.requestSuggestion(mode: mode) },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() }
        )
        // Rebind live whenever Settings records a new shortcut.
        coordinator.onHotkeysChanged = { [weak self] in self?.hotkeys.reload() }

        // Credential checks are asynchronous and silent. An empty startup cache is not
        // evidence that the user has never configured a key; Settings stays user-initiated.
        if (!coordinator.isMock && coordinator.onboarding.state.shouldPresent) ||
            AppPaths.isOnboardingPreview {
            openOnboarding()
        }
    }

    private func applyPreferences(_ settings: AppSettings) {
        hotkeys.setEnabledModes(settings.enabledSuggestionModes)
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
        onboardingWindow?.title = ServiceGuide.text("Welcome to LiveCopilot", "欢迎使用 LiveCopilot", settings.language)
        syncGuidancePresentation()
    }

    private func applyAppearance(to window: NSWindow, background: AppBackground) {
        window.appearance = background.usesLightAppearance ? NSAppearance(named: .aqua) : nil
        if !(window is OverlayWindow) {
            // The SwiftUI material covers the content area, not AppKit's titlebar.
            // A nearly opaque window backing keeps the titlebar legible while
            // retaining the frosted content's small amount of translucency.
            window.isOpaque = background != .frosted
            window.backgroundColor = background == .frosted
                ? NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 0.96)
                : .windowBackgroundColor
        }
    }

    private func localizeMenu(_ menu: NSMenu, language: AppLanguage) {
        for item in menu.items {
            let standard = ["Edit", "View", "Window", "Help", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Close Window", "Minimize", "Zoom", "Bring All to Front", "Hide LiveCopilot", "Hide Others", "Show All", "About LiveCopilot", "Check for Updates…"]
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
        if let onboardingWindow, onboardingWindow.isVisible {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
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

    func openOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        coordinator.onboarding.isPresentingGuide = true
        coordinator.onboarding.reopen()
        let view = OnboardingView(coordinator: coordinator, close: { [weak self] in self?.closeOnboarding() },
                                  beginListening: { [weak self] in
            guard let self else { return }
            self.closeOnboarding()
            Task { await self.coordinator.start() }
        }, beginTyping: { [weak self] in self?.closeOnboarding() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = ServiceGuide.text("Welcome to LiveCopilot", "欢迎使用 LiveCopilot", coordinator.settings.language)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.sharingType = .readOnly
        window.minSize = NSSize(width: 1040, height: 700)
        let visibleSize = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1120, height: 760))
        window.setContentSize(NSSize(width: min(1040, visibleSize.width), height: min(700, visibleSize.height)))
        // Appearance and compact-layout switches apply only to the isolated preview.
        if AppPaths.isOnboardingPreview {
            if ProcessInfo.processInfo.arguments.contains("--onboarding-dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if ProcessInfo.processInfo.arguments.contains("--onboarding-compact") { window.setContentSize(NSSize(width: 1040, height: 700)) }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        onboardingWindow = window
        overlay?.orderOut(nil)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func closeOnboarding() { onboardingWindow?.close() }

    private func syncGuidancePresentation() {
        let guide = coordinator.onboarding.isPresentingGuide
        let tips = coordinator.onboarding.visibleTip != nil
        overlay?.setupWindowVisible = guide
        overlay?.guidanceActive = tips
        if guide { overlay?.orderOut(nil) }
        else if tips { overlay?.reveal() }
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        // Closing the window preserves an in-progress guide; explicit Skip and
        // Finish record their own disposition before arriving here.
        window.contentViewController = nil
        onboardingWindow = nil
        coordinator.onboarding.isPresentingGuide = false
        coordinator.onboarding.enterOverlay()
        syncGuidancePresentation()
        overlay?.reveal(); overlay?.makeKeyAndOrderFront(nil)
    }
}
