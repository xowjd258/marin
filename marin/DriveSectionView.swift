import SwiftUI

struct DriveSectionView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        Section("Drive") {
            HStack {
                Text("Forward")
                Slider(value: Binding(get: { ble.forwardSpeed }, set: { ble.setForward($0) }), in: -1...1)
                Text(String(format: "%.2f", ble.forwardSpeed))
                    .font(.caption)
                    .frame(width: 42)
            }

            HStack {
                Text("Veer")
                Slider(value: Binding(get: { ble.veerSpeed }, set: { ble.setVeer($0) }), in: -1...1)
                Text(String(format: "%.2f", ble.veerSpeed))
                    .font(.caption)
                    .frame(width: 42)
            }

            HStack(spacing: 12) {
                Button("Stop") {
                    ble.stopDrive()
                }
                .buttonStyle(.borderedProminent)

                Button("Emergency Stop") {
                    ble.emergencyStop()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(ble.lightEnabled ? "Light Off" : "Light On") {
                    ble.setLight(enabled: !ble.lightEnabled)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
