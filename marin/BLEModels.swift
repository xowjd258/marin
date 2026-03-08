import CoreBluetooth

struct PeripheralItem: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
}
