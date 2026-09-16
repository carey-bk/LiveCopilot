import SwiftUI

/// Use the bundled, multiresolution application icon in both in-app headers.
struct AppBrandTitle: View {
    var iconSize: CGFloat = 24
    var titleFont: Font = .headline
    private static let icon: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return NSApp.applicationIconImage }
        return image
    }()
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text("LiveCopilot").font(titleFont).lineLimit(1)
        }.fixedSize(horizontal: true, vertical: false)
    }
}
