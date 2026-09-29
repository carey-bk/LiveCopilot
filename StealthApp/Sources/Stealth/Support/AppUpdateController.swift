import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastCheck: Date?
    let enabled: Bool
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    var blockingReason: () -> String? = { nil }
    var prepareForRelaunch: (() async -> Void)?

    #if DEBUG
    // Only the isolated updater QA bundle may use a loopback feed. Release has no override.
    private static var qaFeed: String? {
        guard Bundle.main.bundleIdentifier == "com.livecopilot.updater-qa", AppPaths.isOnboardingPreview,
              let value = Bundle.main.object(forInfoDictionaryKey: "LiveCopilotUpdaterTestFeed") as? String,
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return value
    }
    func feedURLString(for updater: SPUUpdater) -> String? { Self.qaFeed }
    #endif

    init(mock: Bool) {
        var available = !mock && Bundle.main.bundleIdentifier == "com.livecopilot.app"
        #if DEBUG
        available = available || Self.qaFeed != nil
        #endif
        enabled = available
        super.init()
    }

    func start() {
        guard enabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticChecks = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &observations)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = blockingReason() {
            throw NSError(domain: "com.livecopilot.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let prepareForRelaunch else { return false }
        Task { await prepareForRelaunch(); installHandler() }
        return true
    }
}
