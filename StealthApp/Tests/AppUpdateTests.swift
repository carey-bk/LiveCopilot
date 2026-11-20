import XCTest
import Sparkle
import SwiftUI
@testable import LiveCopilot

@MainActor
final class AppUpdateTests: XCTestCase {
    func testPreviewNeverStartsAnUpdaterOrChangesSparklePreferences() {
        let before = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool
        let updates = AppUpdateController(mock: true)
        updates.start()
        updates.start()
        updates.setAutomaticChecks(true)
        updates.checkForUpdates()
        XCTAssertFalse(updates.enabled)
        XCTAssertFalse(updates.canCheck)
        XCTAssertNil(updates.lastCheck)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool, before)
    }

    func testBusySessionRejectsBothManualAndBackgroundChecks() throws {
        let updates = AppUpdateController(mock: true)
        let sdk = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        updates.blockingReason = { "Finish the active session first." }
        for check in [SPUUpdateCheck.updates, .updatesInBackground] {
            XCTAssertThrowsError(try updates.updater(sdk.updater, mayPerform: check)) { error in
                XCTAssertEqual(error.localizedDescription, "请先结束监听、索引或模型准备，再检查更新。")
            }
        }
        updates.blockingReason = { nil }
        XCTAssertNoThrow(try updates.updater(sdk.updater, mayPerform: .updates))
    }

    func testBundledReleasePolicyRequiresSignedUpdatesAndExplicitInstallation() {
        let info = Bundle.main.infoDictionary!
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://carey-bk.github.io/LiveCopilot/updates/appcast.xml")
        XCTAssertEqual(Data(base64Encoded: info["SUPublicEDKey"] as! String)?.count, 32)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testFreshInstallChecksAutomaticallyAndPreservesAnExplicitOptOut() throws {
        let identifier = "com.livecopilot.updater-policy-test." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".bundle")
        let contents = root.appendingPathComponent("Contents")
        let defaults = UserDefaults(suiteName: identifier)!
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = Bundle.main.infoDictionary!
        info["CFBundleIdentifier"] = identifier
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let settings = SPUUpdaterSettings(hostBundle: bundle)
        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertFalse(settings.automaticallyDownloadsUpdates)
        settings.automaticallyChecksForUpdates = false
        XCTAssertFalse(SPUUpdaterSettings(hostBundle: bundle).automaticallyChecksForUpdates)
        settings.automaticallyChecksForUpdates = true
        XCTAssertTrue(SPUUpdaterSettings(hostBundle: bundle).automaticallyChecksForUpdates)
    }
    func testPublicVersionComparisonAndLegacyTags() throws {
        func v(_ value: String) throws -> ReleaseVersion { try XCTUnwrap(ReleaseVersion(value)) }
        XCTAssertGreaterThan(try v("v2.2.10"), try v("2.2.9"))
        XCTAssertGreaterThan(try v("2.10.0"), try v("2.9.99"))
        XCTAssertGreaterThan(try v("3.0.0"), try v("2.99.99"))
        XCTAssertEqual(try v("V2.2.0"), try v("2.2"))
        XCTAssertEqual(try v("2.2.0+local.101"), try v("2.2.0"))
        XCTAssertLessThan(try v("2.3.0-rc.2"), try v("2.3.0-rc.10"))
        XCTAssertLessThan(try v("2.3.0-rc.10"), try v("2.3.0"))
        for invalid in ["20261010.161843", "2.02.0", "2.2.0evil", "v2", "2.2.0.1", ""] {
            XCTAssertNil(ReleaseVersion(invalid))
        }
        XCTAssertEqual(AppInfo.display, ReleaseVersion(AppInfo.version)?.display)
        XCTAssertFalse(AppInfo.display.contains("("))
        XCTAssertEqual(AppInfo.aboutPanelOptions[.applicationVersion] as? String, AppInfo.display)
        XCTAssertEqual(AppInfo.aboutPanelOptions[.version] as? String, "")
    }
    func testSameVersionAndOlderReleaseNeverBecomeUpdates() throws {
        let app = AppUpdateController(mock: true, version: "2.3.0")
        for value in ["2.2.10", "v2.3.0", "2.4.0-beta.1"] {
            app.recordAvailable(.init(version: try XCTUnwrap(ReleaseVersion(value)), notes: "test", supportsInAppInstall: true))
            XCTAssertFalse(app.hasUpdate)
        }
        app.recordAvailable(.init(version: try XCTUnwrap(ReleaseVersion("2.3.1")), notes: "fixed", supportsInAppInstall: true))
        XCTAssertTrue(app.hasUpdate)
    }
    func testBannerSnoozeKeepsMenuBadgeAndUpdateDestination() throws {
        let app = AppUpdateController(mock: true, version: "2.2.0")
        let next = UpdateRelease(version: try XCTUnwrap(ReleaseVersion("2.2.1")), notes: "改进更新体验", supportsInAppInstall: true)
        app.recordAvailable(next)
        XCTAssertTrue(app.showsBanner)
        app.remindLater()
        XCTAssertFalse(app.showsBanner)
        XCTAssertTrue(app.hasUpdate, "Menu marker survives banner dismissal")
        app.recordAvailable(next)
        XCTAssertFalse(app.showsBanner, "Repeated checks must not nag within this session")
        let before = app.managementRequest
        var opened = 0; app.openManagement = { opened += 1 }
        app.viewUpdate()
        XCTAssertEqual(opened, 1); XCTAssertNotEqual(before, app.managementRequest)
    }
    func testActiveSessionSuppressesBannerAndRequiresExplicitRestartAfterward() throws {
        let app = AppUpdateController(mock: true, version: "2.2.0")
        app.recordAvailable(.init(version: try XCTUnwrap(ReleaseVersion("2.2.1")), notes: "fixture", supportsInAppInstall: true))
        var busy = true
        app.blockingReason = { busy ? "Listening" : nil }; app.activityDidChange()
        XCTAssertFalse(app.showsBanner); XCTAssertTrue(app.hasUpdate)
        var choices: [SPUUserUpdateChoice] = []
        app.ready { choices.append($0) }
        app.restartToInstall()
        XCTAssertTrue(choices.isEmpty); XCTAssertFalse(app.installationCommitted)
        busy = false; app.activityDidChange()
        XCTAssertTrue(choices.isEmpty, "Returning to idle must not restart automatically")
        app.restartToInstall()
        XCTAssertEqual(choices, [.install]); XCTAssertTrue(app.installationCommitted)
        app.restartToInstall(); XCTAssertEqual(choices.count, 1)
    }
    func testPlainReleaseNotesDoNotLoadHTMLOrExternalResources() {
        let notes = UpdateRelease.plainNotes("<script>bad()</script><h2>新版</h2><ul><li>改进 &amp; 修复</li></ul><img src='https://invalid.test/tracking'>")
        XCTAssertEqual(notes, "新版\n改进 & 修复")
        XCTAssertEqual(UpdateRelease.officialPage.host, "github.com")
        XCTAssertEqual(UpdateRelease.officialPage.path, "/carey-bk/LiveCopilot/releases")
    }
    func testNoUpdateResultIsChineseAndOnlyShowsPublicVersion() {
        let app = AppUpdateController(mock: true, version: "2.2.2")
        app.notFound(NSError(domain: SUSparkleErrorDomain, code: 1001))
        XCTAssertEqual(app.statusText, "当前已是最新版本 · v2.2.2")
        XCTAssertNil(app.release)
    }
    func testUpdateLayoutsAtMinimumWindowSize() async throws {
        let folder = ProcessInfo.processInfo.environment["LIVECOPILOT_UI_ACCEPTANCE"] ?? ""
        guard !folder.isEmpty, !folder.hasPrefix("$(") else { throw XCTSkip("Opt-in UI rendering") }
        let root = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "com.livecopilot.update-layout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults)
        app.settings.language = .simplifiedChinese
        app.updates.recordAvailable(.init(version: ReleaseVersion("99.2.10")!, notes: "优化本地能力配置，提供场景推荐和清晰的模型状态。\n改进更新体验与版本比较。", supportsInAppInstall: true))
        for width in [820, 1040] {
            let host = NSHostingView(rootView: SettingsView(coordinator: app))
            let size = NSSize(width: width, height: 680)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, size)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("updates-\(width).png"))
            window.orderOut(nil)
        }
        await app.shutdown()
    }

    func testSignedLoopbackFeedDrivesEmbeddedStateAndSemanticFiltering() async throws {
        let fixture = ProcessInfo.processInfo.environment["LIVECOPILOT_UPDATE_FIXTURE"] ?? ""
        guard !fixture.isEmpty, !fixture.hasPrefix("$(") else { throw XCTSkip("Opt-in signed loopback update test") }
        let appURL = URL(fileURLWithPath: fixture).appendingPathComponent("installed/LiveCopilot.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw XCTSkip("Prepare signed loopback QA fixture first") }
        let host = try XCTUnwrap(Bundle(url: appURL))
        let suite = "com.livecopilot.update-integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdateController(mock: true, version: "2.2.0", defaults: defaults, hostBundle: host)
        XCTAssertTrue(updates.enabled)
        updates.start()
        for _ in 0..<100 where !updates.canCheck { try await Task.sleep(nanoseconds: 50_000_000) }
        updates.checkForUpdates()
        for _ in 0..<200 where (updates.release == nil || updates.phase == .checking) && updates.phase != .failed { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(updates.release?.display, "v2.2.1", updates.statusText)
        XCTAssertEqual(updates.phase, .available)
        XCTAssertEqual(updates.release?.supportsInAppInstall, true, "Use Sparkle's signed candidate, not an unverified link")
        updates.remindLater()
        XCTAssertTrue(updates.hasUpdate); XCTAssertFalse(updates.showsBanner)
        let cached = AppUpdateController(mock: true, version: "2.2.0", defaults: defaults, hostBundle: host)
        XCTAssertEqual(cached.release?.display, "v2.2.1")
        XCTAssertTrue(cached.showsBanner, "Snooze lasts only this session")
        let current = AppUpdateController(mock: true, version: "2.2.1", defaults: defaults, hostBundle: host)
        XCTAssertFalse(current.hasUpdate, "Installed release must invalidate an old update cache")
        current.start()
        for _ in 0..<100 where !current.canCheck { try await Task.sleep(nanoseconds: 50_000_000) }
        current.checkForUpdates()
        for _ in 0..<200 where current.phase == .checking { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(current.phase, .upToDate, current.statusText)
        XCTAssertFalse(current.hasUpdate, "The host build is lower but its public version is the same")
    }

    @MainActor func testDismissInstallationResetsReadyToInstallAndNeverWedgesListening() {
        let controller = AppUpdateController(mock: true, version: "2.9.0")
        controller.recordAvailable(.init(version: ReleaseVersion("2.9.1")!, notes: "Stability", supportsInAppInstall: true))
        controller.ready { _ in }
        XCTAssertEqual(controller.phase, .readyToInstall)

        controller.dismissInstallation()
        XCTAssertFalse(controller.installationCommitted)
        XCTAssertEqual(controller.phase, .available)

        // Even if restartToInstall were called when no handler remains, it must never wedge installationCommitted.
        controller.restartToInstall()
        XCTAssertFalse(controller.installationCommitted)
        XCTAssertNotEqual(controller.phase, .installing)
    }

}
