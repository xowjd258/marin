import Foundation

struct MinimumJerkProfile {
    let start: Double
    let end: Double
    let duration: Double

    func position(at elapsed: Double) -> Double {
        guard duration > 0 else { return end }
        let s = min(max(elapsed / duration, 0), 1)
        let blend = (10 * pow(s, 3)) - (15 * pow(s, 4)) + (6 * pow(s, 5))
        return start + (end - start) * blend
    }

    var isInstant: Bool {
        duration <= 0.0001
    }
}
