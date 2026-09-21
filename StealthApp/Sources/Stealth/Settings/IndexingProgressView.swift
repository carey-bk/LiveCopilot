import SwiftUI

/// Real batch progress with an animated highlight while an embedding batch is running.
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
            TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
                GeometryReader { geometry in
                    let count = max(12, min(64, Int(geometry.size.width / 8)))
                    let phase = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % count
                    HStack(spacing: 4) {
                        ForEach(0..<count, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.blue.opacity(index < Int(Double(count) * value) ? 1 :
                                                        (!reduceMotion && index == phase ? 0.7 : 0.16)))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }.frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100))%")
    }
}
