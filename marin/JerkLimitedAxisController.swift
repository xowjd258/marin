import Foundation

struct JerkLimitedAxisController {
    var state: MotionState
    var target: Double

    let positionMin: Double
    let positionMax: Double
    var velocityMax: Double
    let accelerationMax: Double
    let jerkMax: Double
    let deadband: Double

    init(initial: Double,
         positionMin: Double,
         positionMax: Double,
         velocityMax: Double,
         accelerationMax: Double,
         jerkMax: Double,
         deadband: Double) {
        self.state = MotionState(position: initial, velocity: 0, acceleration: 0)
        self.target = initial
        self.positionMin = positionMin
        self.positionMax = positionMax
        self.velocityMax = velocityMax
        self.accelerationMax = accelerationMax
        self.jerkMax = jerkMax
        self.deadband = deadband
    }

    mutating func setTarget(_ value: Double) {
        var next = value
        if abs(next) < deadband {
            next = 0
        }
        target = clamp(next, lower: positionMin, upper: positionMax)
    }

    mutating func forcePosition(_ value: Double) {
        let clipped = clamp(value, lower: positionMin, upper: positionMax)
        state.position = clipped
        state.velocity = 0
        state.acceleration = 0
        target = clipped
    }

    mutating func step(dt: Double) -> MotionState {
        guard dt > 0 else { return state }

        let error = target - state.position
        let kp = 14.0
        let kd = 7.2
        let desiredAcceleration = clamp((kp * error) - (kd * state.velocity), lower: -accelerationMax, upper: accelerationMax)

        let accelDeltaMax = jerkMax * dt
        let accelDelta = clamp(desiredAcceleration - state.acceleration, lower: -accelDeltaMax, upper: accelDeltaMax)
        state.acceleration = clamp(state.acceleration + accelDelta, lower: -accelerationMax, upper: accelerationMax)

        state.velocity = clamp(state.velocity + state.acceleration * dt, lower: -velocityMax, upper: velocityMax)
        state.position = clamp(state.position + state.velocity * dt, lower: positionMin, upper: positionMax)

        if abs(target - state.position) < 0.0025, abs(state.velocity) < 0.02, abs(state.acceleration) < 0.2 {
            state.position = target
            state.velocity = 0
            state.acceleration = 0
        }

        return state
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
