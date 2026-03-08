import SwiftUI

struct DeviceListSectionView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        Section("Discovered Devices") {
            if ble.peripherals.isEmpty {
                Text("No LOOI Robot found yet. Tap Start Scan.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.peripherals) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.body)
                            Text(item.id.uuidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("RSSI \(item.rssi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Connect") {
                            ble.connect(to: item)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
