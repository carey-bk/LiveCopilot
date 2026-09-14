import SwiftUI

/// Keep the same surface treatment across the overlay, settings and history windows.
struct WindowBackgroundView: View {
    let style: AppBackground
    var isOverlay = false

    @ViewBuilder var body: some View {
        switch style {
        case .glass:
            if isOverlay { Rectangle().fill(.regularMaterial) }
            else { Color(nsColor: .windowBackgroundColor) }
        case .frosted:
            Rectangle().fill(.regularMaterial)
                .overlay {
                    // The milky veil reduces backdrop contrast; a faint cool tint adds depth.
                    LinearGradient(
                        colors: [.white.opacity(0.78), Color(red: 0.94, green: 0.96, blue: 0.99).opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
        case .white:
            Color.white
        }
    }
}
