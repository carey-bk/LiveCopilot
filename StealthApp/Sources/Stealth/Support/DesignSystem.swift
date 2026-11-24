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
    static let canvasNSColor = dynamicNS(light: 0xF5F6F8, dark: 0x1B1C1F)
    static let canvas = Color(nsColor: canvasNSColor)
    /// Card and raised surfaces.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x26272B)
    /// Recessed wells inside a card (text editors, inline groups).
    static let well = dynamic(light: 0xF2F3F5, dark: 0x303136)
    static let hairline = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let success = dynamic(light: 0x1E9E5A, dark: 0x3DD68C)
    static let warning = dynamic(light: 0xC2740A, dark: 0xFFB547)
    static let danger = dynamic(light: 0xD93A3A, dark: 0xFF6B6B)

    /// Neutral fills for chips, wells and tracks, tuned per appearance instead of ad-hoc opacities.
    static let fillSubtle = dynamic(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let fill = dynamic(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.09)
    static let fillStrong = dynamic(light: 0x000000, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.16)
    /// The icon's blue-to-pink sweep. Reserved for the primary action, Jev Mode and the focused AI input.
    static let brandGradient = LinearGradient(colors: [accent, accentPink], startPoint: .leading, endPoint: .trailing)

    /// Type scale. Large decorative numerals and the wordmark keep their own fonts.
    enum Typo {
        static let display = Font.system(size: 26, weight: .semibold)
        static let title = Font.system(size: 20, weight: .semibold)
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let callout = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 10, weight: .medium)
    }

    /// Animation curves. Use through `lcAnimation(_:value:)` so Reduce Motion is honored.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let emphasized = Animation.spring(response: 0.5, dampingFraction: 0.72)
    }

    /// Surface depth: flat sits on the canvas, raised is a card, floating is a popover or hovered card.
    enum Elevation { case flat, raised, floating }

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
        Color(nsColor: dynamicNS(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }
    private static func dynamicNS(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Surfaces

extension View {
    /// White (dark: raised gray) card on the window canvas, with layered shadow and, in dark
    /// appearance, a top highlight in place of a flat outline.
    func lcCard(padding: CGFloat = LC.Space.l, elevation: LC.Elevation = .raised) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LCSurface(radius: LC.Radius.card, elevation: elevation))
    }

    /// Shared surface treatment for cards and floating panels.
    func lcSurface(radius: CGFloat = LC.Radius.card, elevation: LC.Elevation = .raised) -> some View {
        modifier(LCSurface(radius: radius, elevation: elevation))
    }

    /// Animation that is dropped under Reduce Motion.
    func lcAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(LCReducibleAnimation(animation: animation, value: value))
    }

    /// Hover feedback for clickable rows and cards: a soft fill, or a lift for raised surfaces.
    func lcHoverable(radius: CGFloat = LC.Radius.control, lift: Bool = false) -> some View {
        modifier(LCHoverable(radius: radius, lift: lift))
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

struct LCSurface: ViewModifier {
    let radius: CGFloat
    let elevation: LC.Elevation
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        let (ambient, key, keyRadius, keyY): (Double, Double, CGFloat, CGFloat) = switch elevation {
        case .flat: (0, 0, 0, 0)
        case .raised: (dark ? 0.30 : 0.04, dark ? 0.28 : 0.05, 10, 3)
        case .floating: (dark ? 0.36 : 0.06, dark ? 0.40 : 0.12, 22, 10)
        }
        content
            .background {
                shape.fill(LC.surface)
                    .shadow(color: .black.opacity(ambient), radius: 1, y: 1)
                    .shadow(color: .black.opacity(key), radius: keyRadius, y: keyY)
            }
            .overlay {
                if dark {
                    // Light falls from above: brighter top edge, fading to the plain hairline.
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.05)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                } else {
                    shape.strokeBorder(LC.hairline)
                }
            }
    }
}

struct LCReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Lets the design gallery render hover states without a pointer.
struct LCForcedHoverKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var lcForcedHover: Bool {
        get { self[LCForcedHoverKey.self] }
        set { self[LCForcedHoverKey.self] = newValue }
    }
}

struct LCHoverable: ViewModifier {
    let radius: CGFloat
    let lift: Bool
    @State private var hovering = false
    @Environment(\.lcForcedHover) private var forced
    func body(content: Content) -> some View {
        let active = hovering || forced
        content
            .background {
                if !lift && active {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(LC.fillSubtle)
                }
            }
            .shadow(color: .black.opacity(lift && active ? 0.08 : 0), radius: 14, y: 6)
            .offset(y: lift && active ? -1 : 0)
            .onHover { hovering = $0 }
            .lcAnimation(LC.Motion.quick, value: active)
    }
}

// MARK: - Buttons

/// Buttons with hover, press and keyboard-focus feedback.
struct LCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        LCButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct LCButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: LCButtonStyle.Kind
    let compact: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lcForcedHover) private var forced
    var body: some View {
        let active = (hovering || forced) && isEnabled
        configuration.label
            .font(compact ? LC.Typo.caption.weight(.semibold) : LC.Typo.callout.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .foregroundStyle(foreground)
            .background { background(active: active) }
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(LC.hairline)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .lcAnimation(LC.Motion.quick, value: active)
            .lcAnimation(LC.Motion.quick, value: configuration.isPressed)
    }
    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .primary
        case .ghost: return LC.accent
        case .danger: return LC.danger
        }
    }
    @ViewBuilder private func background(active: Bool) -> some View {
        switch kind {
        case .primary:
            Capsule().fill(LC.brandGradient)
                .overlay(Capsule().fill(.white.opacity(active ? 0.12 : 0)))
                .shadow(color: LC.accent.opacity(active ? 0.35 : 0.2), radius: active ? 8 : 4, y: 2)
        case .secondary:
            Capsule().fill(active ? LC.fill : LC.fillSubtle)
        case .ghost:
            Capsule().fill(LC.accent.opacity(active ? 0.12 : 0))
        case .danger:
            Capsule().fill(LC.danger.opacity(active ? 0.18 : 0.12))
        }
    }
}

/// Borderless toolbar icon with a circular hover fill.
struct LCIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    func makeBody(configuration: Configuration) -> some View {
        LCIconButtonBody(configuration: configuration, size: size)
    }
}

private struct LCIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lcForcedHover) private var forced
    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .background(Circle().fill((hovering || forced) && isEnabled ? LC.fill : .clear))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .lcAnimation(LC.Motion.quick, value: hovering)
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
        .background(tone == .neutral ? LC.fill : tone.color.opacity(0.12), in: Capsule())
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
    /// Lines of detail before truncating; nil shows all of it.
    var detailLineLimit: Int? = 2
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
                .contentTransition(.numericText())
                .lcAnimation(LC.Motion.standard, value: value)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(detailLineLimit).fixedSize(horizontal: false, vertical: true)
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

// MARK: - Settings building blocks

/// The one card used across Settings: icon tile, title, an optional line of context and an
/// optional status or action on the right, then the card's rows.
struct LCSettingsCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tone: LC.Tone = .accent
    var status: (text: String, tone: LC.Tone)?
    var titleFont: Font = LC.Typo.headline
    let content: Content
    let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: LC.Tone = .accent,
         status: (text: String, tone: LC.Tone)? = nil, titleFont: Font = LC.Typo.headline,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.tone = tone
        self.status = status; self.titleFont = titleFont; self.content = content(); self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
                if let systemImage { LCIconTile(systemImage: systemImage, tone: tone, size: 26) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(titleFont)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, subtitle == nil ? 0 : 1)
                Spacer(minLength: 8)
                if let status { LCPill(text: status.text, tone: status.tone).fixedSize() }
                accessory
            }
            content
        }
        .lcCard()
        .accessibilityElement(children: .contain)
    }
}

extension LCSettingsCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tone: LC.Tone = .accent,
         status: (text: String, tone: LC.Tone)? = nil, titleFont: Font = LC.Typo.headline, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tone: tone, status: status, titleFont: titleFont,
                  content: content, accessory: { EmptyView() })
    }
}

/// One setting: its name and an optional line of explanation on the left, the control on the right.
struct LCSettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    let control: Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.control = control()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .accessibilityElement(children: .contain)
    }
}

/// Compact switch for the right side of a settings row; the title is its accessibility label.
struct LCSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
    }
}

/// A choice shown as a card: icon, name and one line on what it means. Read as a radio button.
struct LCOptionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LC.Radius.card - 2, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    LCIconTile(systemImage: systemImage, tone: selected ? .accent : .neutral, size: 28, filled: selected)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? LC.accent : Color.secondary.opacity(0.45))
                }
                Text(title).font(LC.Typo.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? LC.accent.opacity(0.07) : LC.fillSubtle, in: shape)
            .overlay(shape.strokeBorder(selected ? LC.accent.opacity(0.6) : LC.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .lcHoverable(radius: LC.Radius.card - 2)
        .opacity(isEnabled ? 1 : 0.55)
        .lcAnimation(LC.Motion.quick, value: selected)
        // Label the button itself so its press action stays available to accessibility clients.
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// Sidebar row label; the selected row floats as a card. With a namespace, the selection card
/// slides between rows instead of jumping.
struct LCSidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var badge: String?
    var selection: Namespace.ID?
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
                let card = RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous)
                    .fill(LC.surface)
                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous).strokeBorder(LC.hairline))
                if let selection { card.matchedGeometryEffect(id: "sidebar-selection", in: selection) } else { card }
            }
        }
        .contentShape(Rectangle())
        .lcHoverable(radius: LC.Radius.control)
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

// MARK: - Scrolling

/// Vertical ScrollView with thin, auto-hiding overlay scrollers. With a mouse attached macOS
/// otherwise switches every window to wide, always-visible legacy scrollers with a track.
struct LCScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    /// Padding inside the scrolled content. Use it instead of padding the scroll view, so the
    /// scroll bar stays at the outer edge and does not cover the content.
    var horizontalInset: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(axes) { content().padding(.horizontal, horizontalInset).background(OverlayScrollerProbe()) }
    }
}

/// Finds the enclosing NSScrollView and keeps it on the overlay scroller style, including after
/// the system preference changes when a mouse is connected or removed.
private struct OverlayScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil, window != nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // NSScrollView applies the new system style in its own observer; apply ours after it.
                DispatchQueue.main.async { self?.apply() }
            }
        }
        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Small spinning ring for waits of unknown length; a static partial ring under Reduce Motion.
struct LCSpinner: View {
    var size: CGFloat = 10
    var lineWidth: CGFloat = 1.6
    var color: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}

/// Thin indeterminate bar for work in progress (retrieval, generation). Exists only while shown.
struct LCProgressLine: View {
    var tone: LC.Tone = .accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(tone.color.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [tone.color.opacity(0), tone.color, LC.accentPink.opacity(0.8)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: geometry.size.width * phase)
                }
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            guard !reduceMotion else { phase = 0.3; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.0 }
        }
        .accessibilityHidden(true)
    }
}

/// Wraps children onto new lines, left-aligned (chips, tags).
struct LCFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Two-source live input meter: a few bars that rise with the real capture level.
struct LCLevelBars: View {
    let level: Double
    var tone: LC.Tone = .accent
    private let weights: [Double] = [0.55, 1.0, 0.75]
    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule().fill(level > 0.02 ? tone.color : tone.color.opacity(0.28))
                    .frame(width: 2.5, height: 3 + 9 * CGFloat(min(1, level * weight * 1.3)))
            }
        }
        .frame(height: 12)
        .lcAnimation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}


/// AppKit material behind SwiftUI content (sidebar vibrancy). Follows Reduce Transparency itself.
struct LCVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blending; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material; view.blendingMode = blending
    }
}

/// Capsule segmented control with a sliding thumb. Exposed to accessibility as a segmented Picker.
struct LCSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    /// Optional status dot before each label, for example ready or needs setup.
    var dot: ((Value) -> LC.Tone?)? = nil
    @Namespace private var thumb
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 6) {
                        if let tone = dot?(item.value) { Circle().fill(tone.color).frame(width: 6, height: 6) }
                        Text(item.label).font(LC.Typo.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if selected {
                                Capsule().fill(LC.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(LC.fill, in: Capsule())
        .lcAnimation(LC.Motion.standard, value: selection)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(items, id: \.value) { Text($0.label).tag($0.value) }
            }.pickerStyle(.segmented)
        }
    }
}


/// Small bar chart of real values (most recent last), scaled to the largest value.
struct LCSparkBars: View {
    let values: [Double]
    var tone: LC.Tone = .accent
    var height: CGFloat = 28
    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == values.count - 1 ? tone.color : tone.color.opacity(0.35))
                    .frame(width: 5, height: max(3, height * CGFloat(value / top)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}


/// Passes the pointer-hover state to its content (rows that reveal actions on hover).
struct LCHoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    @Environment(\.lcForcedHover) private var forced
    var body: some View {
        content(hovering || forced).onHover { hovering = $0 }
    }
}

/// Empty state: a symbol on a soft brand halo, a title and one line of guidance.
struct LCEmptyState: View {
    let systemImage: String
    let title: String
    var message: String?
    var compact = false
    var body: some View {
        let size: CGFloat = compact ? 30 : 56
        let layout = compact ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            ZStack {
                Circle().fill(LinearGradient(colors: [LC.accent.opacity(0.14), LC.accentPink.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: systemImage).font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [LC.accent, LC.accentPink], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            VStack(alignment: compact ? .leading : .center, spacing: 4) {
                Text(title).font(compact ? LC.Typo.callout.weight(.semibold) : LC.Typo.headline)
                if let message {
                    Text(message).font(compact ? LC.Typo.caption : LC.Typo.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(compact ? .leading : .center)
                        .frame(maxWidth: compact ? .infinity : 300, alignment: compact ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
