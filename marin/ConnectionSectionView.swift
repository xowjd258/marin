import SwiftUI

struct ConnectionSectionView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        Section("Connection") {
            Text(ble.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let connectedDeviceName = ble.connectedDeviceName {
                Text("Connected: \(connectedDeviceName)")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            if let battery = ble.batteryPercent {
                Text(ble.isCharging ? "Battery: \(battery)% (Charging)" : "Battery: \(battery)%")
                    .font(.subheadline)
                    .foregroundStyle(ble.isCharging ? .blue : .secondary)
            } else {
                Text(ble.isCharging ? "Charging" : "Battery: --")
                    .font(.subheadline)
                    .foregroundStyle(ble.isCharging ? .blue : .secondary)
            }

            Toggle("Auto Scan & Connect", isOn: Binding(
                get: { ble.autoScanConnectEnabled },
                set: { ble.toggleAutoScanConnect($0) }
            ))

            HStack(spacing: 12) {
                Button(ble.isScanning ? "Stop Scan" : "Scan Now") {
                    if ble.isScanning {
                        ble.stopScan()
                    } else {
                        ble.startScan()
                    }
                }
                .buttonStyle(.bordered)

                if ble.connectedDeviceName != nil {
                    Button("Disconnect") {
                        ble.disconnect()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Send Test Command") {
                    ble.sendTestCommand()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
