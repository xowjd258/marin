import Foundation

struct MotionCoordinatorOutput {
    let forward: Double
    let veer: Double
    let head: Double
}

struct MotionCoordinator {
    private(set) var driveForward = JerkLimitedAxisController(
        initial: 0,
        positionMin: -1,
        positionMax: 1,
        velocityMax: 1.0,
        accelerationMax: 1.0,
        jerkMax: 4.8,
        deadband: 0.03
    )

    private(set) var driveVeer = JerkLimitedAxisController(
        initial: 0,
        positionMin: -1,
        positionMax: 1,
        velocityMax: 1.0,
        accelerationMax: 1.2,
        jerkMax: 5.6,
        deadband: 0.03
    )

    private(set) var head = JerkLimitedAxisController(
        initial: 0.85,
        positionMin: 0,
        positionMax: 1,
        velocityMax: 1.1,
        accelerationMax: 1.9,
        jerkMax: 14.0,
        deadband: 0.0
    )

    private var nodQueue: [MinimumJerkProfile] = []
    private var nodElapsed: Double = 0

    mutating func setDriveTargets(forward: Double, veer: Double) {
        var f = shapeInput(forward)
        var v = shapeInput(veer)
        let magnitude = sqrt((f * f) + (v * v))
        if magnitude > 1.0 {
            f /= magnitude
            v /= magnitude
        }
        driveForward.setTarget(f)
        driveVeer.setTarget(v)
    }

    mutating func setHeadTarget(_ target: Double) {
        head.setTarget(target)
        nodQueue.removeAll()
        nodElapsed = 0
    }

    mutating func stopNod() {
        nodQueue.removeAll()
        nodElapsed = 0
    }

    mutating func resetAll() {
        driveForward.forcePosition(0)
        driveVeer.forcePosition(0)
        head.forcePosition(0.85)
        nodQueue.removeAll()
        nodElapsed = 0
    }

    mutating func enqueueSoftNod(from currentAngle: Double) {
        let current = min(max(currentAngle, 0.0), 1.0)
        head.forcePosition(current)
        let downA = max(0.52, current - 0.14)
        let upA = min(0.90, current + 0.08)
        nodQueue = [
            MinimumJerkProfile(start: current, end: current, duration: 0.12),
            MinimumJerkProfile(start: current, end: downA, duration: 0.68),
            MinimumJerkProfile(start: downA, end: upA, duration: 0.60),
            MinimumJerkProfile(start: upA, end: downA + 0.03, duration: 0.58),
            MinimumJerkProfile(start: downA + 0.03, end: current, duration: 0.72)
        ]
        nodElapsed = 0
    }

    var isNodding: Bool {
        !nodQueue.isEmpty
    }

    mutating func step(dt: Double) -> MotionCoordinatorOutput {
        let forward = driveForward.step(dt: dt).position
        let veer = driveVeer.step(dt: dt).position

        if !nodQueue.isEmpty {
            nodElapsed += dt
            let profile = nodQueue[0]
            if profile.isInstant {
                head.forcePosition(profile.end)
                nodQueue.removeFirst()
                nodElapsed = 0
            } else {
                head.forcePosition(profile.position(at: nodElapsed))
                if nodElapsed >= profile.duration {
                    nodQueue.removeFirst()
                    nodElapsed = 0
                }
            }
        }

        let combinedDriveMagnitude = min(1.0, abs(forward) * 0.7 + abs(veer) * 0.5)
        let dynamicHeadCap = 1.4 - (combinedDriveMagnitude * 0.18)
        head.velocityMax = max(0.3, dynamicHeadCap)

        let headPosition: Double
        if nodQueue.isEmpty {
            headPosition = head.step(dt: dt).position
        } else {
            headPosition = head.state.position
        }

        return MotionCoordinatorOutput(forward: forward, veer: veer, head: headPosition)
    }

    private func shapeInput(_ value: Double) -> Double {
        let clamped = min(max(value, -1.0), 1.0)
        return (0.65 * clamped) + (0.35 * clamped * clamped * clamped)
    }
}
