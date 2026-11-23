import AppKit
import Combine
#if MAS_OFFLINE
@MainActor
final class AppUpdateController: ObservableObject {
    enum Phase { case idle, checking, upToDate, available, downloading, extracting, readyToInstall, installing, failed }
    let phase = Phase.idle
    let enabled = false, canCheck = false, isWorking = false, installationCommitted = false
    let showsBanner = false, canInstall = false, automaticChecks = false, hasUpdate = false
    let statusText = "更新由 Mac App Store 提供", message = "", managementRequest = UUID()
    let currentDisplay = AppInfo.version
    let currentVersion = ReleaseVersion(AppInfo.version)
    let latestVersion: ReleaseVersion? = nil, release: UpdateRelease? = nil
    let progress: Double? = nil, lastCheck: Date? = nil
    var blockingReason: () -> String? = { nil }
    var prepareForRelaunch: (() async -> Void)?
    var openManagement: (() -> Void)?
    init(mock: Bool) {}
    func start() {}
    func viewUpdate() {}
    func checkForUpdates() {}
    func setAutomaticChecks(_ enabled: Bool) {}
    func remindLater() {}
    func downloadUpdate() {}
    func restartToInstall() {}
    func cancelDownload() {}
    func activityDidChange() {}
    func retryDeferredCheck() {}
}
#else
import Sparkle

/// One state owner for the settings window, menu bar and embedded update controls.
/// Sparkle retains responsibility for signed feeds, package verification and installation.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Phase: Equatable { case idle, checking, upToDate, available, downloading, extracting, readyToInstall, installing, failed }
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var release: UpdateRelease?
    @Published private(set) var latestVersion: ReleaseVersion?
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    @Published private(set) var bannerDismissed = false
    @Published private(set) var managementRequest = UUID()
    @Published private(set) var installationCommitted = false
    @Published private(set) var activityBlocked = false
    let enabled: Bool
    let currentVersion: ReleaseVersion?
    private let defaults: UserDefaults
    private let hostBundle: Bundle
    private let cacheKey = "livecopilot.update-cache.v1"
    private var updater: SPUUpdater?
    private var driver: AppUpdateDriver?
    private var observations = Set<AnyCancellable>()
    private var latestVerifiedRelease: UpdateRelease?
    private var verifiedVersionCount = 0
    private var requestedInstall: ReleaseVersion?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var postponedRelaunch: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var manualCheck = false
    private var deferredCheck = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    var blockingReason: () -> String? = { nil }
    var prepareForRelaunch: (() async -> Void)?
    var openManagement: (() -> Void)?
    private struct Cache: Codable { let release: UpdateRelease?; let latestVersion: ReleaseVersion?; let checked: Date }

    #if DEBUG
    private var qaFeed: String? {
        guard hostBundle.bundleIdentifier == "com.livecopilot.updater-qa", hostBundle.object(forInfoDictionaryKey: "LiveCopilotOnboardingPreview") as? Bool == true,
              let value = hostBundle.object(forInfoDictionaryKey: "LiveCopilotUpdaterTestFeed") as? String,
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return value
    }
    func feedURLString(for updater: SPUUpdater) -> String? { qaFeed }
    #endif

    init(mock: Bool, version: String = AppInfo.version, defaults: UserDefaults = .standard, hostBundle: Bundle = .main) {
        self.hostBundle = hostBundle
        var available = !mock && hostBundle.bundleIdentifier == "com.livecopilot.app"
        #if DEBUG
        available = available || (hostBundle.bundleIdentifier == "com.livecopilot.updater-qa" && hostBundle.object(forInfoDictionaryKey: "LiveCopilotOnboardingPreview") as? Bool == true)
        #endif
        enabled = available; currentVersion = ReleaseVersion(version); self.defaults = defaults
        if available { automaticChecks = SPUUpdaterSettings(hostBundle: hostBundle).automaticallyChecksForUpdates }
        super.init()
        if available, let data = defaults.data(forKey: cacheKey), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.checked <= Date(), Date().timeIntervalSince(cache.checked) < 7 * 86_400 {
            lastCheck = cache.checked; latestVersion = cache.latestVersion
            if let release = cache.release, isNewer(release.version) { self.release = release; phase = .available }
        }
    }
    var currentDisplay: String { currentVersion?.display ?? "版本未知" }
    var hasUpdate: Bool { release.map { isNewer($0.version) } ?? false }
    var showsBanner: Bool { hasUpdate && !bannerDismissed && blockingReason() == nil && !installationCommitted }
    var isWorking: Bool { [.checking, .downloading, .extracting, .installing].contains(phase) }
    var canInstall: Bool { hasUpdate && blockingReason() == nil && !isWorking && !installationCommitted }
    var statusText: String {
        switch phase {
        case .idle: return enabled ? "尚未检查更新" : "开发与预览版本不检查正式更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "当前已是最新版本 · \(currentDisplay)"
        case .available: return "发现新版本 \(release?.display ?? "")"
        case .downloading: return "正在下载更新…"
        case .extracting: return "正在验证并准备更新…"
        case .readyToInstall: return blockingReason() == nil ? "更新已就绪，可以重启并安装" : "更新已就绪，结束当前任务后可安装"
        case .installing: return "正在安装更新…"
        case .failed: return message.isEmpty ? "更新失败，请稍后重试" : message
        }
    }
    func start() {
        guard enabled, updater == nil else { return }
        let driver = AppUpdateDriver(owner: self); self.driver = driver
        let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticChecks = $0 }.store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &observations)
        do { try updater.start() } catch { fail("更新服务暂不可用，请前往官方发布页。") }
    }
    func viewUpdate() { managementRequest = UUID(); openManagement?() }
    func checkForUpdates() {
        guard enabled, canCheck, !isWorking else { return }
        guard blockingReason() == nil else { message = "请先结束监听、索引或模型准备，再检查更新。"; return }
        manualCheck = true; message = ""; phase = .checking
        updater?.checkForUpdates()
    }
    func setAutomaticChecks(_ enabled: Bool) { guard self.enabled else { return }; updater?.automaticallyChecksForUpdates = enabled }
    func remindLater() { bannerDismissed = true }
    func isNewer(_ version: ReleaseVersion) -> Bool { version.isStable && currentVersion.map { version > $0 } == true }
    func recordAvailable(_ release: UpdateRelease) {
        guard isNewer(release.version) else { return }
        self.release = release; latestVersion = release.version; phase = .available; message = ""; saveCache()
    }
    func downloadUpdate() {
        guard canInstall, let release, release.supportsInAppInstall, canCheck else { return }
        // Cached metadata can show a badge, but never authorizes installing a cached URL.
        requestedInstall = release.version
        checkForUpdates()
    }
    func restartToInstall() {
        guard phase == .readyToInstall, blockingReason() == nil else { return }
        if let postponedRelaunch {
            installationCommitted = true; phase = .installing
            self.postponedRelaunch = nil
            finishRelaunch(postponedRelaunch)
        } else if let reply = installReply {
            installationCommitted = true; phase = .installing
            installReply = nil
            reply(.install)
        } else {
            installationCommitted = false
            phase = hasUpdate ? .available : .idle
        }
    }
    func cancelDownload() {
        cancellation?(); cancellation = nil; requestedInstall = nil
        phase = hasUpdate ? .available : .idle; progress = nil
    }
    func activityDidChange() {
        let blocked = blockingReason() != nil
        if activityBlocked != blocked { activityBlocked = blocked }
        retryDeferredCheck()
    }
    func retryDeferredCheck() {
        guard deferredCheck, enabled, automaticChecks, canCheck, blockingReason() == nil else { return }
        deferredCheck = false; updater?.checkForUpdatesInBackground()
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if blockingReason() != nil {
            if updateCheck == .updatesInBackground { deferredCheck = true }
            throw NSError(domain: "com.livecopilot.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先结束监听、索引或模型准备，再检查更新。"])
        }
    }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        latestVerifiedRelease = nil; verifiedVersionCount = 0
        guard appcast.signingValidationStatus == .succeeded else { return }
        let versions = appcast.items.compactMap { item -> UpdateRelease? in
            guard item.channel == nil, item.isMacOsUpdate,
                  let version = ReleaseVersion(item.displayVersionString), version.isStable else { return nil }
            return UpdateRelease(version: version, notes: UpdateRelease.plainNotes(item.itemDescription), supportsInAppInstall: false)
        }
        verifiedVersionCount = versions.count
        latestVerifiedRelease = versions.max { $0.version < $1.version }
        latestVersion = latestVerifiedRelease?.version
    }
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        // Sparkle supplies its OS/channel-filtered candidates. Keep all installer safeguards.
        appcast.items.filter { item in
            item.signingValidationStatus == .succeeded && ReleaseVersion(item.displayVersionString).map(isNewer) == true
        }.max { (ReleaseVersion($0.displayVersionString)!) < (ReleaseVersion($1.displayVersionString)!) } ?? SUAppcastItem.empty()
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded, ReleaseVersion(item.displayVersionString).map(isNewer) == true else {
            throw NSError(domain: "com.livecopilot.updates", code: 2, userInfo: [NSLocalizedDescriptionKey: "未发现更新的正式版本。"])
        }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { notFound(error as NSError) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        if ns.domain == SUSparkleErrorDomain && ns.code == 1001 { return }
        DebugLog.log("updater.abort domain=\(ns.domain) code=\(ns.code)")
        requestedInstall = nil
        if manualCheck || [.downloading, .extracting, .installing].contains(phase) { fail("检查或更新失败，请检查网络后重试。") }
        else if phase == .checking { phase = hasUpdate ? .available : .idle }
        manualCheck = false
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        if blockingReason() != nil || !installationCommitted {
            installationCommitted = false; phase = .readyToInstall; postponedRelaunch = handler
        } else { finishRelaunch(handler) }
        return true
    }
    private func finishRelaunch(_ handler: @escaping () -> Void) {
        Task { await prepareForRelaunch?(); handler() }
    }
    fileprivate func found(_ item: SUAppcastItem, stage: SPUUserUpdateStage, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard item.signingValidationStatus == .succeeded, let version = ReleaseVersion(item.displayVersionString), isNewer(version) else { reply(.dismiss); return }
        let entry = UpdateRelease(version: version, notes: UpdateRelease.plainNotes(item.itemDescription), supportsInAppInstall: !item.isInformationOnlyUpdate)
        recordAvailable(entry)
        if stage == .installing { ready(reply); return }
        let authorized = requestedInstall == version && blockingReason() == nil && entry.supportsInAppInstall
        requestedInstall = nil; manualCheck = false
        if authorized { phase = .downloading; reply(.install) } else { reply(.dismiss) }
    }
    func notFound(_ error: NSError) {
        // A marketing-newer release whose build/OS cannot be installed safely uses the official download page.
        if let latestVerifiedRelease, isNewer(latestVerifiedRelease.version) {
            recordAvailable(latestVerifiedRelease)
        } else if let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
           item.signingValidationStatus == .succeeded, let version = ReleaseVersion(item.displayVersionString), isNewer(version) {
            recordAvailable(.init(version: version, notes: UpdateRelease.plainNotes(item.itemDescription), supportsInAppInstall: false))
        } else if updater != nil && verifiedVersionCount == 0 {
            if manualCheck { fail("暂时无法确认最新正式版本，请稍后重试。") }
        } else {
            release = nil; phase = .upToDate; message = ""; saveCache()
        }
        requestedInstall = nil; manualCheck = false
    }
    func ready(_ reply: @escaping (SPUUserUpdateChoice) -> Void) { installReply = reply; phase = .readyToInstall; progress = nil }
    fileprivate func fail(_ text: String) { message = text; phase = .failed; installationCommitted = false; requestedInstall = nil }
    fileprivate func checking(_ cancel: @escaping () -> Void) { cancellation = cancel; phase = .checking }
    fileprivate func downloading(_ cancel: @escaping () -> Void) {
        cancellation = cancel; phase = .downloading; receivedBytes = 0; expectedBytes = 0; progress = nil
    }
    fileprivate func expected(_ count: UInt64) { expectedBytes = count }
    fileprivate func received(_ count: UInt64) {
        receivedBytes += count; if expectedBytes > 0 { progress = min(1, Double(receivedBytes) / Double(expectedBytes)) }
    }
    fileprivate func extracting(_ value: Double? = nil) { cancellation = nil; phase = .extracting; progress = value }
    func dismissInstallation() {
        cancellation = nil; installReply = nil; requestedInstall = nil; manualCheck = false; progress = nil
        if [.checking, .downloading, .extracting, .readyToInstall, .installing].contains(phase) {
            installationCommitted = false
            phase = hasUpdate ? .available : .idle
        }
    }
    fileprivate func notes(_ data: SPUDownloadData) {
        guard release != nil, let text = String(data: data.data, encoding: .utf8) else { return }
        release?.notes = UpdateRelease.plainNotes(text); saveCache()
    }
    private func saveCache() {
        guard enabled else { return }
        let checked = Date(); lastCheck = checked
        if let data = try? JSONEncoder().encode(Cache(release: release, latestVersion: latestVersion, checked: checked)) { defaults.set(data, forKey: cacheKey) }
    }
}

@MainActor
private final class AppUpdateDriver: NSObject, SPUUserDriver {
    weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: owner?.automaticChecks ?? true, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { owner?.checking(cancellation) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { owner?.found(appcastItem, stage: state.stage, reply: reply) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { owner?.notes(downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { owner?.notFound(error as NSError); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { owner?.fail("更新失败，请检查网络或稍后重试。"); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { owner?.downloading(cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { owner?.expected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { owner?.received(length) }
    func showDownloadDidStartExtractingUpdate() { owner?.extracting() }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.extracting(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { owner?.ready(reply) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { owner?.dismissInstallation() }
    func showUpdateInFocus() { owner?.viewUpdate() }
}

#endif
