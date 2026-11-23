import AppKit
import SwiftUI

/// LiveCopilot visual tokens and shared components. Colors adapt to light and dark
/// appearance; views use these instead of ad-hoc opacities, radii and system colors.
enum LC {
    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 14
        static let panel: CGFloat = 16
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Brand blue from the app icon.
    static let accent = dynamic(light: 0x1A73E8, dark: 0x4C93FF)
    /// Brand pink from the app icon; the far-end speaker and secondary highlights.
    static let accentPink = dynamic(light: 0xD9488B, dark: 0xFF7AB5)
    /// Window canvas behind cards.
    static let canvas = dynamic(light: 0xF5F6F8, dark: 0x1B1C1F)
    /// Card and raised surfaces.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x26272B)
    /// Recessed wells inside a card (text editors, inline groups).
    static let well = dynamic(light: 0xF2F3F5, dark: 0x303136)
    static let hairline = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let success = dynamic(light: 0x1E9E5A, dark: 0x3DD68C)
    static let warning = dynamic(light: 0xC2740A, dark: 0xFFB547)
    static let danger = dynamic(light: 0xD93A3A, dark: 0xFF6B6B)

    enum Tone {
        case neutral, accent, pink, success, warning, danger
        var color: Color {
            switch self {
            case .neutral: return .secondary
            case .accent: return LC.accent
            case .pink: return LC.accentPink
            case .success: return LC.success
            case .warning: return LC.warning
            case .danger: return LC.danger
            }
        }
    }

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Surfaces

extension View {
    /// White (dark: raised gray) card with a hairline border on the window canvas.
    func lcCard(padding: CGFloat = LC.Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LC.surface, in: RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous).strokeBorder(LC.hairline))
    }

    /// Recessed area inside a card.
    func lcWell(radius: CGFloat = LC.Radius.control) -> some View {
        self.background(LC.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(LC.hairline))
    }

    /// Tinted note block (pricing, guidance, notices).
    func lcCallout(_ tone: LC.Tone = .accent, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.color.opacity(0.07), in: RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous).strokeBorder(tone.color.opacity(0.14)))
    }
}

// MARK: - Components

/// Rounded square holding an SF Symbol, placed before card titles.
struct LCIconTile: View {
    let systemImage: String
    var tone: LC.Tone = .accent
    var size: CGFloat = 22
    var filled = false
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tone.color)
            .frame(width: size, height: size)
            .background(filled ? tone.color : tone.color.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Small status or attribute label.
struct LCPill: View {
    let text: String
    var tone: LC.Tone = .neutral
    var systemImage: String?
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tone == .neutral ? Color.primary.opacity(0.06) : tone.color.opacity(0.12), in: Capsule())
    }
}

/// Colored dot for live state; pulses unless Reduce Motion is on.
struct LCStatusDot: View {
    var tone: LC.Tone = .success
    var pulsing = false
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle().fill(tone.color).frame(width: size, height: size)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle().stroke(tone.color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
            }
            .onAppear { pulse = pulsing }
            .onChange(of: pulsing) { _, value in pulse = value }
            .accessibilityHidden(true)
    }
}

/// Section title row: optional icon tile, title, optional subtitle and trailing accessory.
struct LCSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tone: LC.Tone = .accent
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
            if let systemImage { LCIconTile(systemImage: systemImage, tone: tone) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension LCSectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: LC.Tone = .accent) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tone: tone) { EmptyView() }
    }
}

/// Page heading: breadcrumb, large title and one-line description.
struct LCPageHeader: View {
    var breadcrumb: [String] = []
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !breadcrumb.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(breadcrumb.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                        Text(item)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 24, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// Status card: icon tile and title, a prominent value, a detail line and an optional footer action.
struct LCStatTile<Footer: View>: View {
    let title: String
    let value: String
    var detail: String?
    var systemImage: String
    var tone: LC.Tone = .accent
    var badge: (text: String, tone: LC.Tone)?
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LCIconTile(systemImage: systemImage, tone: tone, filled: true)
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let badge { LCPill(text: badge.text, tone: badge.tone) }
            }
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer()
        }
        .lcCard(padding: 14)
    }
}

extension LCStatTile where Footer == EmptyView {
    init(title: String, value: String, detail: String? = nil, systemImage: String, tone: LC.Tone = .accent, badge: (text: String, tone: LC.Tone)? = nil) {
        self.init(title: title, value: value, detail: detail, systemImage: systemImage, tone: tone, badge: badge) { EmptyView() }
    }
}

/// Segmented dot bar for real proportions (index progress, audio level, activity).
struct LCDotMeter: View {
    /// 0...1
    let fraction: Double
    var segments = 20
    var tone: LC.Tone = .accent
    var height: CGFloat = 8
    var body: some View {
        let filled = Int((min(max(fraction, 0), 1) * Double(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filled ? tone.color : tone.color.opacity(0.12))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

/// Sidebar row label; the selected row floats as a card.
struct LCSidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var badge: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? LC.accent : Color.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let badge { Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous)
                    .fill(LC.surface)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous).strokeBorder(LC.hairline))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Small uppercase group label in the sidebar.
struct LCSidebarGroupLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
            .foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 6)
    }
}
