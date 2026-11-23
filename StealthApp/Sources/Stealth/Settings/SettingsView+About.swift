import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var about: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppBrandTitle(iconSize: 64, titleSize: 28)
            Text(AppInfo.display).foregroundStyle(.secondary).textSelection(.enabled)
            Text(b("A native macOS conversation copilot. Listen, find relevant knowledge, and get words you can say aloud.",
                   "原生 macOS 对话助手。听取对话、查找相关资料，生成可以直接说出口的回答。"))
                .font(.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: AppInfo.repositoryURL) {
                    HStack(spacing: 9) {
                        Image("GitHub-Mark")
                            .resizable().renderingMode(.template)
                            .frame(width: 21, height: 21)
                            .accessibilityHidden(true)
                        Text(AppInfo.starTitle(coordinator.settings.language))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 34)
                    .frame(maxWidth: 328, minHeight: 42)
                    .foregroundStyle(.primary)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "star")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 26)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.trailing, 8)
                            .accessibilityHidden(true)
                    }
                    .background(LC.surface, in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11).strokeBorder(
                            LinearGradient(colors: [
                                Color(red: 0.88, green: 0.76, blue: 0.52),
                                Color(red: 0.65, green: 0.52, blue: 0.31)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2.5
                        )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-repository")
                Text(AppInfo.starThanks(coordinator.settings.language))
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                Link(destination: URL(string: "https://github.com/carey-bk")!) {
                    Label(b("Author on GitHub", "作者 GitHub 主页"), systemImage: "person.crop.circle")
                }.accessibilityIdentifier("about-author")
                Link(destination: URL(string: coordinator.settings.language.usesTraditionalChinese ? "https://carey-bk.github.io/LiveCopilot/zh-Hant/" : coordinator.settings.language.usesChinese
                                       ? "https://carey-bk.github.io/LiveCopilot/"
                                       : "https://carey-bk.github.io/LiveCopilot/en/")!) {
                    Label(b("Product guide · 中文 / English", "使用介绍 · 中文 / English"), systemImage: "globe")
                }.accessibilityIdentifier("about-guide")
            }.buttonStyle(.link)
            Button { showDiagnostics = true } label: {
                Label(b("Report a problem…", "反馈问题与诊断报告…"), systemImage: "ladybug")
            }.accessibilityIdentifier("diagnostics-open")
            Divider()
            UpdateSettingsView(updates: updates, language: coordinator.settings.language)
        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
