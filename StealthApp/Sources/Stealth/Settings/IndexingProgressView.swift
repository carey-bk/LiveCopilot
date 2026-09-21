import SwiftUI

/// Completed work is dark blue; remaining work stays pale blue.
struct IndexingProgressView: View {
    let progress: Double
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var value: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let count = max(12, min(64, Int(geometry.size.width / 8)))
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { index in
                        let fill = min(1, max(0, value * Double(count) - Double(index)))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.blue.opacity(0.16))
                            .overlay(alignment: .leading) {
                                GeometryReader { segment in
                                    Color.blue.frame(width: segment.size.width * fill)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                            }
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
            }.frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100))%")
    }
}
