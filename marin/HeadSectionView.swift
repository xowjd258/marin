import SwiftUI

struct HeadSectionView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        Section("Head") {
            HStack {
                Text("Angle")
                Slider(value: Binding(get: { ble.headAngle }, set: { ble.setHeadAngle($0) }), in: 0...1)
                Text(String(format: "%.2f", ble.headAngle))
                    .font(.caption)
                    .frame(width: 42)
            }

            HStack(spacing: 12) {
                Button(ble.isNodding ? "Nodding..." : "Nod") {
                    ble.nodHead()
                }
                .buttonStyle(.bordered)
                .disabled(ble.isNodding)

                Button("Stop Nod") {
                    ble.stopNod()
                }
                .buttonStyle(.bordered)
                .disabled(!ble.isNodding)
            }
        }
    }
}
