#if DEBUG
import AppKit
import SwiftUI

/// Debug-only workbench (`--mock --ui-gallery`): every LC token and component in light and dark,
/// with hover states forced on, so polish can be judged side by side in one snapshot.
struct DesignGallery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column.environment(\.colorScheme, .light).background(LC.canvas).environment(\.colorScheme, .light)
            column.environment(\.colorScheme, .dark).background(LC.canvas).environment(\.colorScheme, .dark)
        }
        .frame(width: 1240)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Type") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display 26 实时副驾").font(LC.Typo.display)
                    Text("Title 20 设置与概览").font(LC.Typo.title)
                    Text("Headline 15 知识库检索").font(LC.Typo.headline)
                    Text("Body 13 用于判断提问是否完整。").font(LC.Typo.body)
                    Text("Callout 12 资源已安装 · 开始使用后验证").font(LC.Typo.callout)
                    Text("Caption 11 第 4 步，共 6 步").font(LC.Typo.caption).foregroundStyle(.secondary)
                    Text("MICRO 10").font(LC.Typo.micro).foregroundStyle(.secondary)
                    Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 20))
                }
            }
            group("Color") {
                HStack(spacing: 6) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(swatch.1).frame(width: 44, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(LC.hairline))
                            Text(swatch.0).font(LC.Typo.micro).foregroundStyle(.secondary)
                        }
                    }
                }
                Capsule().fill(LC.brandGradient).frame(height: 8)
            }
            group("Buttons · normal / hover") {
                buttons
                buttons.environment(\.lcForcedHover, true)
            }
            group("Pills, dots, meters") {
                HStack(spacing: 6) {
                    LCPill(text: "已就绪", tone: .success, systemImage: "checkmark")
                    LCPill(text: "生成中", tone: .accent)
                    LCPill(text: "自动建议", tone: .pink, systemImage: "waveform")
                    LCPill(text: "待验证")
                    LCPill(text: "失败", tone: .danger)
                }
                HStack(spacing: 12) {
                    LCStatusDot(tone: .success); LCStatusDot(tone: .warning); LCStatusDot(tone: .danger); LCStatusDot(tone: .neutral)
                    LCSpinner(size: 12, color: LC.accent)
                    LCDotMeter(fraction: 0.62, segments: 16).frame(width: 180)
                }
            }
            group("Surfaces · flat / raised / floating / hover") {
                HStack(spacing: 12) {
                    surface("Flat", .flat)
                    surface("Raised", .raised)
                    surface("Floating", .floating)
                    surface("Hover", .raised).lcHoverable(radius: LC.Radius.card, lift: true).environment(\.lcForcedHover, true)
                }
            }
            group("Sidebar and stat tile") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        LCSidebarGroupLabel(title: "Live")
                        LCSidebarItem(title: "概览", systemImage: "square.grid.2x2", selected: true)
                        LCSidebarItem(title: "服务", systemImage: "shippingbox", selected: false)
                    }.frame(width: 190)
                    LCStatTile(title: "知识库", value: "3 份资料", detail: "42 个证据片段 · 混合知识", systemImage: "books.vertical", tone: .success, badge: ("就绪", .success))
                        .frame(width: 260)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("开始监听") {}.buttonStyle(LCButtonStyle(kind: .primary))
            Button("恢复推荐") {}.buttonStyle(LCButtonStyle(kind: .secondary))
            Button("高级设置") {}.buttonStyle(LCButtonStyle(kind: .ghost))
            Button("删除") {}.buttonStyle(LCButtonStyle(kind: .danger))
            Button("小按钮") {}.buttonStyle(LCButtonStyle(kind: .secondary, compact: true))
            Button { } label: { Image(systemName: "gearshape") }.buttonStyle(LCIconButtonStyle())
            Button("停用") {}.buttonStyle(LCButtonStyle(kind: .primary)).disabled(true)
        }
    }

    private var swatches: [(String, Color)] {
        [("canvas", LC.canvas), ("surface", LC.surface), ("well", LC.well), ("fill", LC.fill), ("accent", LC.accent),
         ("pink", LC.accentPink), ("success", LC.success), ("warning", LC.warning), ("danger", LC.danger)]
    }

    private func surface(_ title: String, _ elevation: LC.Elevation) -> some View {
        Text(title).font(LC.Typo.callout).frame(width: 110, height: 64).lcSurface(elevation: elevation)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(LC.Typo.micro).tracking(0.5).foregroundStyle(.tertiary)
            content()
        }
    }

    @MainActor static func open() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Design Gallery"
        window.contentView = NSHostingView(rootView: DesignGallery())
        window.center()
        window.makeKeyAndOrderFront(nil)
        retained = window
    }
    @MainActor private static var retained: NSWindow?
}
#endif
