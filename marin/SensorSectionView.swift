import SwiftUI

struct SensorSectionView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        Section("Sensors") {
            Toggle("Safety Interlock", isOn: Binding(get: { ble.safetyInterlockEnabled }, set: { ble.setSafetyInterlockEnabled($0) }))

            HStack {
                Text("Obstacle Threshold")
                Slider(value: Binding(get: { Double(ble.obstacleThreshold) }, set: { ble.setObstacleThreshold(Int($0)) }), in: 5...200, step: 1)
                Text("\(ble.obstacleThreshold)")
                    .font(.caption)
                    .frame(width: 32)
            }

            HStack {
                Text("Preemptive Margin")
                Slider(value: Binding(get: { Double(ble.preemptiveMargin) }, set: { ble.setPreemptiveMargin(Int($0)) }), in: 0...120, step: 1)
                Text("\(ble.preemptiveMargin)")
                    .font(.caption)
                    .frame(width: 32)
            }

            Text(ble.safetyInterlockActive ? "Interlock: ACTIVE" : "Interlock: Normal")
                .foregroundStyle(ble.safetyInterlockActive ? .red : .secondary)

            Text("Cliff LF/RF/LB/RB: \(ble.cliffLeftFront ? "1" : "0") / \(ble.cliffRightFront ? "1" : "0") / \(ble.cliffLeftBack ? "1" : "0") / \(ble.cliffRightBack ? "1" : "0")")
                .font(.caption)

            Text("Evade L/R: \(ble.evadeLeft.map(String.init) ?? "--") / \(ble.evadeRight.map(String.init) ?? "--")")
                .font(.caption)

            Text("ToF: \(ble.tofDistance.map(String.init) ?? "--")")
                .font(.caption)

            Text("Fused Obstacle: \(ble.fusedObstacleDistance.map(String.init) ?? "--")")
                .font(.caption)

            Text("Touch L/R: \(ble.touchLeft ? "1" : "0") / \(ble.touchRight ? "1" : "0")")
                .font(.caption)

            Text("Phone Attached: \(ble.phoneAttached == nil ? "--" : (ble.phoneAttached == true ? "Yes" : "No"))")
                .font(.caption)
        }
    }
}
