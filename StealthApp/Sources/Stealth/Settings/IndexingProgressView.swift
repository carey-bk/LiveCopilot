import SwiftUI

/// A single determinate bar for the entire import/re-index batch.
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
            ProgressView(value: value, total: 1)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100))%")
    }
}
