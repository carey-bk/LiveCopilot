import Foundation
import Combine
import AVFoundation
import CoreGraphics
import AppKit

@MainActor final class OnboardingStore: ObservableObject {
    @Published var state: OnboardingState { didSet { state.save(defaults: defaults) } }
    @Published var tour: OverlayTourState { didSet { tour.save(defaults: defaults) } }
    @Published var isPresentingGuide = false
    var visibleTip: OverlayTourState.Step? { !isPresentingGuide && tour.disposition == .active ? tour.step : nil }
    let isNewInstall: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults, dataDirectory: URL) {
        self.defaults = defaults
        // SessionStore may have created an empty directory during startup. Only
        // actual stored content is evidence of prior use.
        let existingData = ["knowledge", "sessions", "history", "Laya"].contains {
            !((try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.appendingPathComponent($0).path)) ?? []).isEmpty
        }
        isNewInstall = defaults.object(forKey: OnboardingState.defaultsKey) == nil &&
            defaults.object(forKey: "livecopilot.settings") == nil && !existingData
        state = OnboardingState.load(defaults: defaults, hasExistingData: existingData)
        tour = OverlayTourState.load(defaults: defaults, newInstall: isNewInstall)
        state.save(defaults: defaults)
        tour.save(defaults: defaults)
    }
    func reopen() { state.reopen() }
    func deferSetup() { state.disposition = .deferred }
    func complete() { state.disposition = .completed }
    func enterOverlay() { tour.enterOverlay() }
    func replayTips() { tour.replay() }
    func advanceTip() { tour.advance() }
    func dismissTips() { tour.disposition = .dismissed }
}

/// Permission requests are explicit actions; refreshing never presents a prompt.
@MainActor final class OnboardingPermissions: ObservableObject {
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var screenAudio = CGPreflightScreenCaptureAccess()
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var requestedScreenAudio = false
    let mock: Bool
    init(mock: Bool) { self.mock = mock }
    func refresh() {
        guard !mock else { return }
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        screenAudio = CGPreflightScreenCaptureAccess()
    }
    func requestMicrophone() async {
        guard !mock, !requestingMicrophone else { return }
        requestingMicrophone = true
        defer { requestingMicrophone = false }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }
    func requestScreenAudio() {
        guard !mock else { return }
        requestedScreenAudio = true
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }
    func openSettings(microphone: Bool) {
        guard !mock else { return }
        let section = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) { NSWorkspace.shared.open(url) }
    }
}
