import AppKit
import SwiftUI

/// Keep the same surface treatment across the overlay, settings and history windows.
struct WindowBackgroundView: View {
    let style: AppBackground
    var isOverlay = false

    #if arch(x86_64)
    static let isIntelHost = true
    #else
    static let isIntelHost = false
    #endif

    /// Avoid real-time behind-window Gaussian blur (`.regularMaterial`) on Intel Macs or
    /// when macOS Reduce Transparency is enabled: live backdrop blur over video conferencing
    /// apps (e.g. Microsoft Teams) forces WindowServer out of hardware video overlay planes.
    static func usesLightweightSurface(
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        isIntel: Bool = isIntelHost
    ) -> Bool {
        isIntel || reduceTransparency
    }

    @ViewBuilder var body: some View {
        let lightweight = Self.usesLightweightSurface()
        switch style {
        case .glass:
            if isOverlay {
                if lightweight {
                    Color(nsColor: .windowBackgroundColor).opacity(0.94)
                } else {
                    Rectangle().fill(.regularMaterial)
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        case .frosted:
            if lightweight {
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.98, blue: 0.995).opacity(0.96),
                        Color(red: 0.93, green: 0.95, blue: 0.985).opacity(0.95)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            } else {
                Rectangle().fill(.regularMaterial)
                    .overlay {
                        // The milky veil reduces backdrop contrast; a faint cool tint adds depth.
                        LinearGradient(
                            colors: [.white.opacity(0.78), Color(red: 0.94, green: 0.96, blue: 0.99).opacity(0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    }
            }
        case .white:
            Color.white
        }
    }
}
