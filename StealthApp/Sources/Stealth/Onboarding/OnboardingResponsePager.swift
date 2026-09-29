import AppKit
import SwiftUI

/// A service can return an arbitrarily long answer. Keep it readable without growing the guide.
struct OnboardingResponsePager: View {
    let text: String
    let language: AppLanguage
    @State private var page = 0
    var body: some View {
        GeometryReader { geometry in
            let pages = OnboardingTextPages.split(text, size: CGSize(width: geometry.size.width, height: geometry.size.height - 36))
            let index = min(page, pages.count - 1)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: pages[index]).font(.system(size: 14)).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Button(ServiceGuide.text("Previous", "上一页", language)) { page = max(0, index - 1) }
                        .disabled(index == 0)
                    Text("\(index + 1) / \(pages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button(ServiceGuide.text("Next", "下一页", language)) { page = min(pages.count - 1, index + 1) }
                        .disabled(index == pages.count - 1)
                    Spacer()
                }.opacity(pages.count > 1 ? 1 : 0).disabled(pages.count == 1)
                    .accessibilityHidden(pages.count == 1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.onChange(of: text.isEmpty) { _, empty in if empty { page = 0 } }
    }
}

enum OnboardingTextPages {
    /// Measure with the displayed font; split only at grapheme boundaries and preserve every character.
    static func split(_ text: String, size: CGSize) -> [String] {
        guard !text.isEmpty else { return [""] }
        let characters = Array(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]
        let width = max(40, size.width - 8), height = max(24, size.height - 8)
        var pages: [String] = [], start = 0
        while start < characters.count {
            var low = 1, high = characters.count - start
            while low < high {
                let count = (low + high + 1) / 2
                let candidate = NSAttributedString(string: String(characters[start..<(start + count)]), attributes: attributes)
                let bounds = candidate.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                if ceil(bounds.height) <= height { low = count } else { high = count - 1 }
            }
            var end = start + low
            // Prefer a word boundary near the end, while keeping progress for unbroken text.
            if end < characters.count,
               let boundary = (start + max(1, low * 3 / 4)..<end).last(where: { characters[$0].isWhitespace }) {
                end = boundary + 1
            }
            pages.append(String(characters[start..<end]))
            start = end
        }
        return pages
    }
}
