import AppKit

/// Marketing version is user-facing; the independent build number is diagnostic only.
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static var display: String { ReleaseVersion(version)?.display ?? "版本未知" }
    static var diagnostic: String { "\(display) · Build \(build)" }
    static let repositoryURL = URL(string: "https://github.com/carey-bk/LiveCopilot")!

    static func starTitle(_ language: AppLanguage) -> String {
        ServiceGuide.text("Star on GitHub", "给作者 Github 点个 star🌟", language)
    }

    static func starThanks(_ language: AppLanguage) -> String {
        ServiceGuide.text("Thanks for supporting LiveCopilot!", "感谢你支持 LiveCopilot！", language)
    }

    static func aboutPanelOptions(language: AppLanguage) -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(string: starTitle(language), attributes: [.link: repositoryURL])
        credits.append(NSAttributedString(string: "\n" + starThanks(language)))
        return [.applicationVersion: display, .version: "", .credits: credits]
    }
}
