import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// About: a brand header, three equal action tiles, software update and a quiet footer.
extension SettingsView {
    var about: some View {
        aboutContent.task { await stars.refresh(mock: coordinator.isMock) }
    }
    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            aboutHero
            HStack(alignment: .top, spacing: 12) {
                Link(destination: AppInfo.repositoryURL) {
                    AboutTile(title: b("Star on GitHub", "在 GitHub 点亮 Star"),
                              detail: AppInfo.starThanks(coordinator.settings.language), gold: true) {
                        GitHubMarkBadge()
                    } accessory: {
                        GitHubStarButton(count: stars.count)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppInfo.starTitle(coordinator.settings.language))
                .accessibilityIdentifier("about-repository")

                Link(destination: guideURL) {
                    AboutTile(title: b("Product guide", "使用介绍"), detail: b("Features and setup guide", "功能与配置说明 · 中文 / English")) {
                        LCIconTile(systemImage: "book.pages", tone: .accent, size: 34)
                    } accessory: { linkArrow }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-guide")

                Button { showDiagnostics = true } label: {
                    AboutTile(title: b("Report a problem", "反馈问题"), detail: b("Create a diagnostic report to share privately", "生成诊断报告，私下发送给作者")) {
                        LCIconTile(systemImage: "ladybug", tone: .pink, size: 34)
                    } accessory: { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("diagnostics-open")
            }
            .fixedSize(horizontal: false, vertical: true)

            UpdateSettingsView(updates: updates, language: coordinator.settings.language)

            HStack(spacing: 6) {
                Link(destination: URL(string: "https://github.com/carey-bk")!) {
                    Label(b("Author on GitHub", "作者 GitHub 主页"), systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("about-author")
                Text("·")
                Link(b("MIT License", "MIT 开源许可"), destination: AppInfo.repositoryURL.appendingPathComponent("blob/main/LICENSE"))
                Text("·")
                Text(b("Built on the open-source Stealth project", "基于开源项目 Stealth"))
            }
            .buttonStyle(.link)
            .font(LC.Typo.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.top, 4).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guideURL: URL {
        URL(string: coordinator.settings.language.usesTraditionalChinese ? "https://carey-bk.github.io/LiveCopilot/zh-Hant/"
            : coordinator.settings.language.usesChinese ? "https://carey-bk.github.io/LiveCopilot/" : "https://carey-bk.github.io/LiveCopilot/en/")!
    }

    private var linkArrow: some View {
        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
    }

    private var aboutHero: some View {
        VStack(spacing: 10) {
            Image(nsImage: AppBrandTitle.icon).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
                .shadow(color: LC.accent.opacity(0.25), radius: 18, y: 8)
                .accessibilityHidden(true)
            Text("LiveCopilot").font(.custom(AppBrandTitle.fontName, size: 28))
            HStack(spacing: 8) {
                LCPill(text: AppInfo.display, tone: .accent)
                Text("Build \(AppInfo.build)").font(LC.Typo.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(b("A native macOS conversation copilot. Listen, find relevant knowledge, and get words you can say aloud.",
                   "原生 macOS 对话助手。听取对话、查找相关资料，生成可以直接说出口的回答。"))
                .font(LC.Typo.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 560).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 24)
        .background {
            // A soft glow from the icon's two brand colors, kept faint so text stays primary.
            ZStack {
                RadialGradient(colors: [LC.accent.opacity(0.13), .clear], center: UnitPoint(x: 0.35, y: 0), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [LC.accentPink.opacity(0.10), .clear], center: UnitPoint(x: 0.7, y: 0.1), startRadius: 0, endRadius: 300)
            }
            .clipShape(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
        }
        .lcSurface()
    }
}

/// One equal-width action card on the About page.
private struct AboutTile<Icon: View, Accessory: View>: View {
    let title: String
    let detail: String
    /// Pale champagne-gold finish for the one tile that asks for support.
    var gold = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                icon()
                Spacer(minLength: 4)
                accessory()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(LC.Typo.body.weight(.semibold)).foregroundStyle(gold ? AnyShapeStyle(Gold.ink) : AnyShapeStyle(.primary))
                Text(detail).font(LC.Typo.caption).foregroundStyle(gold ? AnyShapeStyle(Gold.inkSoft) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if gold {
            content.modifier(GoldSurface())
        } else {
            content
                .lcSurface()
                .contentShape(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
                .lcHoverable(radius: LC.Radius.card, lift: true)
        }
    }
}

/// Champagne-gold palette; deep bronze in dark appearance.
private enum Gold {
    static let ink = adaptive(light: (0.42, 0.30, 0.05), dark: (0.96, 0.84, 0.55))
    static let inkSoft = adaptive(light: (0.52, 0.40, 0.17), dark: (0.85, 0.74, 0.50))
    static let fillTop = adaptive(light: (1.00, 0.98, 0.92), dark: (0.24, 0.20, 0.12))
    static let fillBottom = adaptive(light: (0.97, 0.91, 0.75), dark: (0.17, 0.14, 0.09))
    static let rimLight = adaptive(light: (0.94, 0.83, 0.55), dark: (0.86, 0.71, 0.38))
    static let rimDeep = adaptive(light: (0.78, 0.62, 0.27), dark: (0.62, 0.48, 0.22))
    static let glow = Color(red: 0.86, green: 0.68, blue: 0.27)
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Soft gold gradient, a fine gold rim, a warm glow, and a light sheen that sweeps across on hover.
private struct GoldSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var sweep = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous)
        content
            .background {
                ZStack {
                    LinearGradient(colors: [Gold.fillTop, Gold.fillBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                    // Faint highlight in the top-left corner, like light on brushed metal.
                    RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 180)
                        .blendMode(.softLight)
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.45)
                            .rotationEffect(.degrees(18))
                            .offset(x: sweep ? proxy.size.width * 1.3 : -proxy.size.width * 0.6)
                            .opacity(reduceMotion ? 0 : 1)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Gold.rimLight, Gold.rimDeep, Gold.rimLight],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: hovering ? 1.5 : 1)
            }
            .shadow(color: Gold.glow.opacity(hovering ? 0.32 : 0.16), radius: hovering ? 14 : 8, y: hovering ? 5 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .contentShape(shape)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : LC.Motion.standard) { hovering = inside }
                guard inside, !reduceMotion else { return }
                sweep = false
                withAnimation(.easeInOut(duration: 0.9)) { sweep = true }
            }
    }
}

/// Looks like GitHub's own Star button: outlined star, "Star", and the star count in a separate segment.
private struct GitHubStarButton: View {
    let count: Int?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let border = dark ? Color(red: 0.24, green: 0.27, blue: 0.31) : Color(red: 0.82, green: 0.85, blue: 0.88)
        let fill = dark ? Color(red: 0.13, green: 0.15, blue: 0.18) : Color(red: 0.965, green: 0.973, blue: 0.98)
        let ink = dark ? Color(red: 0.94, green: 0.96, blue: 0.98) : Color(red: 0.15, green: 0.16, blue: 0.18)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "star").font(.system(size: 11, weight: .semibold))
                Text("Star").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 9)
            if let count {
                Rectangle().fill(border).frame(width: 1)
                Text(count.formatted(.number.notation(.compactName)))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07), in: Capsule())
                    .padding(.horizontal, 6)
            }
        }
        .foregroundStyle(ink)
        .frame(height: 24)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(border))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The public star count of the repository, cached for six hours. Anonymous, no cookies; hidden on failure.
@MainActor final class GitHubStarCount: ObservableObject {
    @Published private(set) var count: Int?
    private static let countKey = "livecopilot.github.stars", dateKey = "livecopilot.github.stars.date"
    private var loading = false
    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.countKey) != nil { count = defaults.integer(forKey: Self.countKey) }
    }
    func refresh(mock: Bool) async {
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: Self.dateKey) as? Date, Date().timeIntervalSince(date) < 6 * 3600, count != nil { return }
        guard !mock, !loading, let api = URL(string: "https://api.github.com/repos" + AppInfo.repositoryURL.path) else { return }
        loading = true; defer { loading = false }
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stars = object["stargazers_count"] as? Int else { return }
        count = stars
        defaults.set(stars, forKey: Self.countKey); defaults.set(Date(), forKey: Self.dateKey)
    }
}

/// The GitHub mark in a monochrome disc that inverts with the appearance.
private struct GitHubMarkBadge: View {
    /// A loose bundle SVG is not a template image; mark it so it takes the badge's color.
    private static let mark: NSImage = {
        let image = Bundle.main.url(forResource: "GitHub-Mark", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous)
            .fill(dark ? Color.white : Color(red: 0.12, green: 0.13, blue: 0.15))
            .frame(width: 34, height: 34)
            .overlay {
                Image(nsImage: Self.mark).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundColor(dark ? .black : .white)
                    .frame(width: 18, height: 18)
            }
            .accessibilityHidden(true)
    }
}
