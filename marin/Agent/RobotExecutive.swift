import Combine
import Foundation

@MainActor
final class RobotExecutive: ObservableObject {
    @Published var statusText: String = "Executive idle"
    var onMotionTriggered: (() -> Void)?
    var onSafetyStopTriggered: (() -> Void)?
    var onEmotionRequested: ((FaceEmotion) -> Void)?
    /// Called after a move/turn command finishes so caller can capture a post-movement snapshot
    var onMovementCompleted: (() -> Void)?

    private weak var ble: BLEManager?

    func bind(ble: BLEManager) {
        self.ble = ble
    }

    func emergencyStop() {
        ble?.emergencyStop()
        statusText = "Emergency stop executed"
        onSafetyStopTriggered?()
    }

    func setLight(enabled: Bool) {
        ble?.setLight(enabled: enabled)
        statusText = enabled ? "Light on" : "Light off"
    }

    func applyDrive(forward: Double, veer: Double, durationMs: Int) {
        guard let ble else { return }
        ble.setForward(forward)
        ble.setVeer(veer)
        statusText = "Drive applied f=\(String(format: "%.2f", forward)) v=\(String(format: "%.2f", veer))"
        onMotionTriggered?()

        let delay = max(50, durationMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak ble] in
            ble?.stopDrive()
        }
    }

    func triggerNod() {
        ble?.nodHead()
        statusText = "Head nod triggered"
        onMotionTriggered?()
    }

    func setHeadAngle(_ angle: Double) {
        ble?.setHeadAngle(angle)
        statusText = "Head angle: \(String(format: "%.2f", angle))"
    }

    /// Move in a direction (0-360°) for a distance (cm) at a given speed (cm/s).
    /// 0°=forward, 90°=right, 180°=backward, 270°=left.
    func moveDirection(angleDeg: Double, distanceCm: Double, speedCmPerSec: Double) {
        guard let ble else { return }
        let maxSpeedCmPerSec = 25.0
        let speedNorm = min(max(speedCmPerSec / maxSpeedCmPerSec, 0.05), 1.0)
        let angleRad = angleDeg * .pi / 180.0
        let forward = cos(angleRad) * speedNorm
        let veer = -sin(angleRad) * speedNorm
        let durationMs = max(100, Int((distanceCm / max(speedCmPerSec, 1.0)) * 1000))
        ble.setForward(forward)
        ble.setVeer(veer)
        statusText = "Move \(Int(angleDeg))° \(Int(distanceCm))cm"
        onMotionTriggered?()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self, weak ble] in
            ble?.stopDrive()
            // Brief delay for robot to settle before capturing snapshot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.onMovementCompleted?()
            }
        }
    }

    /// Spin in place. Positive degrees = clockwise (right), negative = counterclockwise (left).
    func turn(degrees: Double, speed: String) {
        guard let ble else { return }
        let veerNorm: Double
        let durationPer90: Double  // ms per 90° at this speed
        switch speed {
        case "slow":  veerNorm = 0.45; durationPer90 = 6000
        case "fast":  veerNorm = 0.80; durationPer90 = 2500
        default:      veerNorm = 0.60; durationPer90 = 4500
        }
        let veer = degrees >= 0 ? -veerNorm : veerNorm
        let durationMs = max(300, Int(abs(degrees) / 90.0 * durationPer90))
        ble.setForward(0)
        ble.setVeer(veer)
        statusText = "Turn \(Int(degrees))°"
        onMotionTriggered?()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { [weak self, weak ble] in
            ble?.stopDrive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.onMovementCompleted?()
            }
        }
    }

    /// Head control: angle in degrees (-45=down, 0=level, 90=up),
    /// speed ("slow"/"normal"/"fast"), repeat count (1=hold, >1=nod).
    func headMove(angleDeg: Double, speed: String, repeats: Int) {
        guard let ble else { return }
        // Map degrees: -45°=down(headAngle≈0.25), 0°=level(0.5), 90°=up(1.0)
        // headAngle 1.0 → BLE byte 0 → UP, headAngle 0.0 → BLE byte 255 → DOWN
        let bleAngle = max(0.0, min(1.0, 0.5 + (angleDeg / 180.0)))

        if repeats <= 1 {
            ble.setHeadAngle(bleAngle)
            statusText = "Head \(Int(angleDeg))°"
            return
        }

        // Nod: use speed-based commands for responsiveness
        // Use fixed nod parameters based on speed — angle doesn't scale nod amplitude
        // because even small angles need visible motion for a proper nod
        let adjSpeed: Int8
        let adjDuration: TimeInterval
        switch speed {
        case "slow":  adjSpeed = 12; adjDuration = 0.40
        case "fast":  adjSpeed = 22; adjDuration = 0.20
        default:      adjSpeed = 16; adjDuration = 0.30
        }
        // Determine direction: positive angle (up) = negative speed byte (down first for nod)
        let downSpeed = angleDeg >= 0 ? -adjSpeed : adjSpeed
        let upSpeed = angleDeg >= 0 ? adjSpeed : -adjSpeed

        var steps: [(speed: Int8, duration: TimeInterval)] = []
        for _ in 0..<repeats {
            steps.append((speed: downSpeed, duration: adjDuration))
            steps.append((speed: 0, duration: adjDuration * 0.35))
            steps.append((speed: upSpeed, duration: adjDuration))
            steps.append((speed: 0, duration: adjDuration * 0.35))
        }
        ble.nodSteps = steps
        ble.nodStepStartedAt = nil
        ble.nodCurrentSpeed = 0
        ble.nodLastWriteAt = nil
        ble.isNodding = true
        statusText = "Nod \(repeats)x \(Int(angleDeg))°"
        onMotionTriggered?()
    }

    func execute(intent: RobotIntent) {
        if let byCode = LooiFaceCodeMap.emotion(for: intent.emotionCode) {
            onEmotionRequested?(byCode)
        } else if let mapped = FaceEmotion.from(intent.emotion) {
            onEmotionRequested?(mapped)
        }

        if let command = intent.command?.lowercased() {
            switch command {
            case "stop":
                emergencyStop()
                return
            case "nod":
                triggerNod()
                return
            case "forward":
                applyDrive(forward: 0.18, veer: 0, durationMs: 900)
                return
            default:
                break
            }
        }

        if let headType = intent.head?.type?.lowercased(), headType == "nod" {
            triggerNod()
        }

        if let motion = intent.motion,
           (motion.type?.lowercased() ?? "") == "drive" {
            let f = motion.forward ?? 0
            let v = motion.veer ?? 0
            let d = motion.durationMs ?? 900
            applyDrive(forward: f, veer: v, durationMs: d)
        }
    }
}
