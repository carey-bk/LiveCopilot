import SwiftUI

enum OnboardingMotion {
    // Preview-only slow playback lets native screenshots inspect the same interpolation.
    static var speed: Double {
        AppPaths.isOnboardingPreview && ProcessInfo.processInfo.arguments.contains("--onboarding-slow-motion") ? 0.2 : 1
    }
}

/// The same quiet color field travels between pages instead of restarting with each page.
struct OnboardingAtmosphere: View {
    let step: OnboardingStep
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var pink: UnitPoint {
        switch step {
        case .language: return UnitPoint(x: 0.08, y: 0.18)
        case .introduction: return UnitPoint(x: 0.32, y: 0.06)
        case .models: return UnitPoint(x: 0.72, y: 0.15)
        case .analysis: return UnitPoint(x: 0.94, y: 0.48)
        case .permissions: return UnitPoint(x: 0.62, y: 0.86)
        case .ready: return UnitPoint(x: 0.16, y: 0.62)
        }
    }
    private var blue: UnitPoint {
        switch step {
        case .language: return UnitPoint(x: 0.94, y: 0.90)
        case .introduction: return UnitPoint(x: 0.83, y: 0.66)
        case .models: return UnitPoint(x: 0.22, y: 0.82)
        case .analysis: return UnitPoint(x: 0.08, y: 0.46)
        case .permissions: return UnitPoint(x: 0.24, y: 0.06)
        case .ready: return UnitPoint(x: 0.88, y: 0.28)
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [Color(red: 0.96, green: 0.58, blue: 0.73).opacity(colorScheme == .dark ? 0.13 : 0.19), .clear],
                               center: pink, startRadius: 0, endRadius: geometry.size.width * 0.78)
                RadialGradient(colors: [Color(red: 0.43, green: 0.67, blue: 0.98).opacity(colorScheme == .dark ? 0.16 : 0.21), .clear],
                               center: blue, startRadius: 0, endRadius: geometry.size.width * 0.78)
            }.animation(reduceMotion ? nil : .easeInOut(duration: 1.2).speed(OnboardingMotion.speed), value: step)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct OnboardingStepProgress: View {
    let step: OnboardingStep
    let language: AppLanguage
    let reduceMotion: Bool
    private var label: String {
        ServiceGuide.text("Step \(step.rawValue + 1) of 6", "第 \(step.rawValue + 1) 步，共 6 步", language)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor.opacity(item == step ? 1 : 0.55) : Color.primary.opacity(0.12))
                        .frame(width: item == step ? 46 : 26, height: 7)
                }
            }.frame(width: 206, alignment: .leading)
                .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.86).speed(OnboardingMotion.speed), value: step)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25).speed(OnboardingMotion.speed), value: step)
        }.accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityIdentifier("onboarding-step-progress")
    }
}

/// Text-only action: color and underline provide feedback without adding button chrome.
struct OnboardingQuietButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        OnboardingQuietButtonLabel(label: configuration.label, pressed: configuration.isPressed, reduceMotion: reduceMotion)
    }
}

private struct OnboardingQuietButtonLabel: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    let reduceMotion: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled && (hovered || pressed) ? Color.accentColor : Color.secondary)
            .underline(isEnabled && hovered, color: Color.accentColor.opacity(0.6))
            .opacity(isEnabled ? (pressed ? 0.65 : 1) : 0.45)
            .padding(.horizontal, 4).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}
