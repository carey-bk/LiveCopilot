import SwiftUI

/// Use the bundled, multiresolution application icon in both in-app headers.
struct AppBrandTitle: View {
    var iconSize: CGFloat = 24
    var titleSize: CGFloat = 15
    static let fontName = "AvenirNext-HeavyItalic"
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
            Text("LiveCopilot").font(.custom(Self.fontName, size: titleSize)).lineLimit(1)
        }.fixedSize(horizontal: true, vertical: false)
    }
}

/// Jev Mode is the headline feature, so its name always uses the wordmark face.
enum JevBrand {
    static let name = "Jev Mode"
    /// `text` with every "Jev Mode" set in the wordmark face at `size`; other runs keep the
    /// font applied to the returned Text.
    static func text(_ text: String, size: CGFloat) -> Text {
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: name) {
            attributed[range].swiftUI.font = .custom(AppBrandTitle.fontName, size: size)
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}
