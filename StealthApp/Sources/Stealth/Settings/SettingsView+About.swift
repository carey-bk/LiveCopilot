import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// About: a brand header, three equal action tiles, software update and a quiet footer.
extension SettingsView {
    var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            aboutHero
            HStack(alignment: .top, spacing: 12) {
                Link(destination: AppInfo.repositoryURL) {
                    AboutTile(title: b("Star on GitHub", "在 GitHub 点亮 Star"),
                              detail: AppInfo.starThanks(coordinator.settings.language)) {
                        GitHubMarkBadge()
                    } accessory: {
                        Label("Star", systemImage: "star.fill").labelStyle(.titleAndIcon)
                            .font(LC.Typo.micro.weight(.semibold)).foregroundStyle(LC.warning)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(LC.warning.opacity(0.12), in: Capsule())
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
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                icon()
                Spacer(minLength: 4)
                accessory()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(LC.Typo.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(LC.Typo.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lcSurface()
        .contentShape(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
        .lcHoverable(radius: LC.Radius.card, lift: true)
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
