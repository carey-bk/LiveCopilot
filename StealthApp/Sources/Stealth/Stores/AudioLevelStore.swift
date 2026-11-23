import Foundation
import Combine

/// Live input levels for the overlay meter, sampled from the capture flow monitors at 15 Hz
/// while listening. Kept apart from AppCoordinator so the meter, not the whole overlay, redraws.
@MainActor
final class AudioLevelStore: ObservableObject {
    @Published private(set) var you: Double = 0
    @Published private(set) var them: Double = 0
    private var timer: Timer?
    private var frozen = false

    func start(sample: @escaping @MainActor () -> (you: Double, them: Double)) {
        stop()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.frozen else { return }
                let value = sample()
                // Skip imperceptible changes; always publish a drop to silence.
                if abs(value.you - self.you) > 0.03 || (value.you == 0 && self.you != 0) { self.you = value.you }
                if abs(value.them - self.them) > 0.03 || (value.them == 0 && self.them != 0) { self.them = value.them }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if you != 0 { you = 0 }
        if them != 0 { them = 0 }
    }

    #if DEBUG
    /// Screenshot fixtures only.
    func applyFixture(you: Double, them: Double) { frozen = true; self.you = you; self.them = them }
    #endif
}
