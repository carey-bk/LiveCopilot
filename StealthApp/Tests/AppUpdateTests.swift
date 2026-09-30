import XCTest
import Sparkle
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
                XCTAssertEqual(error.localizedDescription, "Finish the active session first.")
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
}
