import CoreBluetooth

enum BLEUUIDs {
    static let dpService = CBUUID(string: "000000FF-0000-1000-8000-00805F9B34FB")
    static let infoService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")

    static let sequence = CBUUID(string: "0000FE00-0000-1000-8000-00805F9B34FB")
    static let move = CBUUID(string: "0000FED0-0000-1000-8000-00805F9B34FB")
    static let clamp = CBUUID(string: "0000FED1-0000-1000-8000-00805F9B34FB")
    static let light = CBUUID(string: "0000FED2-0000-1000-8000-00805F9B34FB")
    static let stick = CBUUID(string: "0000FED4-0000-1000-8000-00805F9B34FB")
    static let cliff = CBUUID(string: "0000FED5-0000-1000-8000-00805F9B34FB")
    static let evade = CBUUID(string: "0000FED6-0000-1000-8000-00805F9B34FB")
    static let power = CBUUID(string: "0000FED8-0000-1000-8000-00805F9B34FB")
    static let notify = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")
    static let log = CBUUID(string: "0000FEF0-0000-1000-8000-00805F9B34FB")

    static let serialNumber = CBUUID(string: "00002A29-0000-1000-8000-00805F9B34FB")
    static let firmware = CBUUID(string: "00002A27-0000-1000-8000-00805F9B34FB")
    static let hardware = CBUUID(string: "00002A28-0000-1000-8000-00805F9B34FB")

    static let requiredNotify: Set<CBUUID> = [notify, log]
    static let handshakeReadOrder: [CBUUID] = [serialNumber, firmware, hardware, cliff, evade, power, stick]
}
