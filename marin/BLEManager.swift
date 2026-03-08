import Combine
import CoreBluetooth
import SwiftUI

@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published var isBluetoothReady = false
    @Published var isScanning = false
    @Published var autoScanConnectEnabled = true
    @Published var statusText = "Ready"
    @Published var peripherals: [PeripheralItem] = []
    @Published var connectedDeviceName: String?
    @Published var isSessionReady = false
    @Published var batteryPercent: Int?
    @Published var isCharging = false
    @Published var safetyInterlockEnabled = true
    @Published var safetyInterlockActive = false
    @Published var obstacleThreshold: Int = 80
    @Published var preemptiveMargin: Int = 20
    @Published var fusedObstacleDistance: Int?
    @Published var cliffLeftFront = false
    @Published var cliffRightFront = false
    @Published var cliffLeftBack = false
    @Published var cliffRightBack = false
    @Published var evadeLeft: Int?
    @Published var evadeRight: Int?
    @Published var touchLeft = false
    @Published var touchRight = false
    @Published var phoneAttached: Bool?
    @Published var tofDistance: Int?
    @Published var forwardSpeed: Double = 0
    @Published var veerSpeed: Double = 0
    @Published var headAngle: Double = 0.85
    @Published var isNodding = false
    @Published var lightEnabled = false

    var onSafetyInterlockTriggered: ((String) -> Void)?

    var central: CBCentralManager!
    var discoveredById: [UUID: PeripheralItem] = [:]
    var selectedPeripheral: CBPeripheral?
    var writeCharacteristic: CBCharacteristic?
    var keepAliveTimer: Timer?
    var sessionLoopTimer: Timer?
    var driveLoopTimer: Timer?
    var reconnectWorkItem: DispatchWorkItem?
    var shouldAutoReconnect = false
    var nextSequence: UInt8 = 0
    var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    var notificationsEnabled: Set<CBUUID> = []
    var pendingHandshakeReads: [CBUUID] = []
    var activeReadUUID: CBUUID?
    var pendingServiceDiscoveryCount = 0
    var lastSentForward: Int8 = 0
    var lastSentVeer: Int8 = 0
    var lastSentHeadByte: UInt8?
    var lastDriveWriteAt: Date?
    var lastHeadWriteAt: Date?
    var lastControlWriteAt: Date?
    var filteredForwardByte: Double = 0
    var filteredVeerByte: Double = 0
    var filteredHeadByte: Double = 0
    var headCommandDirty = false
    var nodSteps: [(speed: Int8, duration: TimeInterval)] = []
    var nodStepStartedAt: Date?
    var nodCurrentSpeed: Int8 = 0
    var nodLastWriteAt: Date?
    var motionCoordinator = MotionCoordinator()
    var hasAttemptedAutoConnectThisScan = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard isBluetoothReady else {
            statusText = "Bluetooth is not ready"
            return
        }

        stopScan()
        discoveredById.removeAll()
        peripherals.removeAll()
        hasAttemptedAutoConnectThisScan = false
        statusText = "Scanning..."
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func connect(to item: PeripheralItem) {
        stopScan()
        reconnectWorkItem?.cancel()
        shouldAutoReconnect = true
        selectedPeripheral = item.peripheral
        resetCharacteristicState()
        isSessionReady = false
        connectedDeviceName = nil
        statusText = "Connecting to \(item.name)..."
        central.connect(item.peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func toggleAutoScanConnect(_ enabled: Bool) {
        autoScanConnectEnabled = enabled
        if enabled {
            if isBluetoothReady, connectedDeviceName == nil, selectedPeripheral == nil {
                startScan()
            }
        } else {
            stopScan()
        }
    }

    func disconnect() {
        shouldAutoReconnect = false
        reconnectWorkItem?.cancel()
        stopConnectionMaintenance()
        stopSessionLoop()
        stopDriveLoop()

        guard let peripheral = selectedPeripheral else {
            connectedDeviceName = nil
            statusText = "Disconnected"
            return
        }

        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
            statusText = "Disconnecting..."
        } else {
            connectedDeviceName = nil
            statusText = "Disconnected"
        }
    }

    func sendTestCommand() {
        sendSequencePing()
    }

    func setForward(_ value: Double) {
        if safetyInterlockActive, value > 0 {
            forwardSpeed = 0
            motionCoordinator.setDriveTargets(forward: 0, veer: veerSpeed)
            return
        }
        forwardSpeed = max(-1.0, min(1.0, value))
        motionCoordinator.setDriveTargets(forward: forwardSpeed, veer: veerSpeed)
    }

    func setVeer(_ value: Double) {
        if safetyInterlockActive {
            veerSpeed = 0
            // Allow backward drive (forward < 0) even when interlock is active
            let allowedForward = forwardSpeed < 0 ? forwardSpeed : 0.0
            motionCoordinator.setDriveTargets(forward: allowedForward, veer: 0)
            return
        }
        veerSpeed = max(-1.0, min(1.0, value))
        motionCoordinator.setDriveTargets(forward: forwardSpeed, veer: veerSpeed)
    }

    func stopDrive() {
        forwardSpeed = 0
        veerSpeed = 0
        filteredForwardByte = 0
        filteredVeerByte = 0
        lastSentForward = 0
        lastSentVeer = 0
        motionCoordinator.setDriveTargets(forward: 0, veer: 0)
        flushDriveCommand(force: true, dt: 0.02)
    }

    func emergencyStop() {
        nodSteps.removeAll()
        nodStepStartedAt = nil
        nodCurrentSpeed = 0
        nodLastWriteAt = nil
        isNodding = false
        sendHeadSpeedCommand(0, force: true)

        forwardSpeed = 0
        veerSpeed = 0
        filteredForwardByte = 0
        filteredVeerByte = 0
        lastSentForward = 0
        lastSentVeer = 0
        motionCoordinator.setDriveTargets(forward: 0, veer: 0)
        flushDriveCommand(force: true, dt: 0.02)

        statusText = "Emergency stop sent"
    }

    func stopNod() {
        nodSteps.removeAll()
        nodStepStartedAt = nil
        nodCurrentSpeed = 0
        nodLastWriteAt = nil
        sendHeadSpeedCommand(0, force: true)
        isNodding = false
        statusText = "Session ready"
    }

    func setLight(enabled: Bool) {
        guard let peripheral = selectedPeripheral,
              peripheral.state == .connected,
              let characteristic = discoveredCharacteristics[BLEUUIDs.light],
              isWritable(characteristic) else {
            statusText = "Light characteristic not ready"
            return
        }

        let payload = Data([enabled ? 0x01 : 0x00])
        write(payload, to: characteristic, peripheral: peripheral)
        lightEnabled = enabled
        statusText = enabled ? "Light on" : "Light off"
    }

    func setHeadAngle(_ value: Double) {
        let clamped = max(0.0, min(1.0, value))
        headAngle = clamped
        motionCoordinator.setHeadTarget(clamped)
        headCommandDirty = true
    }

    func nodHead() {
        guard !isNodding else { return }
        // Balanced nod: total displacement ≈ 0 so head returns to original position
        // DOWN(-) then UP(+), net displacement: (-5.6 + 5.6) + (-2.4 + 2.4) = 0
        nodSteps = [
            (speed: -16, duration: 0.35),
            (speed: 0, duration: 0.14),
            (speed: 14, duration: 0.40),
            (speed: 0, duration: 0.14),
            (speed: -10, duration: 0.24),
            (speed: 0, duration: 0.16),
            (speed: 10, duration: 0.24),
            (speed: 0, duration: 0.14)
        ]
        nodStepStartedAt = nil
        nodCurrentSpeed = 0
        nodLastWriteAt = nil
        isNodding = true
        statusText = "Nodding"
    }

    func didConnect(_ peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        selectedPeripheral = peripheral
        connectedDeviceName = peripheral.name ?? "Unknown"
        statusText = "Connected to \(connectedDeviceName ?? "device"). Discovering services..."
        peripheral.delegate = self

        resetCharacteristicState()
        isSessionReady = false
        batteryPercent = nil
        isCharging = false
        safetyInterlockActive = false
        clearSensorState()
        lightEnabled = false
        forwardSpeed = 0
        veerSpeed = 0
        lastSentForward = 0
        lastSentVeer = 0
        lastSentHeadByte = nil
        lastDriveWriteAt = nil
        lastHeadWriteAt = nil
        lastControlWriteAt = nil
        filteredForwardByte = 0
        filteredVeerByte = 0
        headAngle = 0.85
        filteredHeadByte = (1.0 - headAngle) * 255.0
        headCommandDirty = false
        nodSteps.removeAll()
        nodStepStartedAt = nil
        nodCurrentSpeed = 0
        nodLastWriteAt = nil
        isNodding = false
        motionCoordinator.resetAll()
        motionCoordinator.setDriveTargets(forward: 0, veer: 0)
        motionCoordinator.setHeadTarget(headAngle)

        peripheral.discoverServices([BLEUUIDs.dpService, BLEUUIDs.infoService])
        startConnectionMaintenance()
        startDriveLoop()
    }

    func didDisconnect(_ peripheral: CBPeripheral, reason: String) {
        stopConnectionMaintenance()
        stopSessionLoop()
        stopDriveLoop()
        resetCharacteristicState()
        isSessionReady = false
        batteryPercent = nil
        isCharging = false
        safetyInterlockActive = false
        clearSensorState()
        lightEnabled = false
        isNodding = false
        connectedDeviceName = nil
        statusText = "Disconnected: \(reason)"

        if shouldAutoReconnect, selectedPeripheral?.identifier == peripheral.identifier {
            scheduleReconnect(for: peripheral)
        } else if autoScanConnectEnabled, isBluetoothReady {
            selectedPeripheral = nil
            startScan()
        }
    }

    func handleBluetoothUnavailable(_ message: String) {
        isBluetoothReady = false
        shouldAutoReconnect = false
        stopConnectionMaintenance()
        stopSessionLoop()
        stopDriveLoop()
        statusText = message
    }

    func discoverResult(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard isLooiDevice(peripheral: peripheral, advertisementData: advertisementData) else { return }
        let fallbackName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"
        let item = PeripheralItem(id: peripheral.identifier, peripheral: peripheral, name: fallbackName, rssi: rssi.intValue)
        discoveredById[peripheral.identifier] = item
        updatePeripheralList()

        if autoScanConnectEnabled,
           isScanning,
           !hasAttemptedAutoConnectThisScan,
           selectedPeripheral == nil,
           connectedDeviceName == nil {
            hasAttemptedAutoConnectThisScan = true
            connect(to: item)
        }
    }

    func markNotifyEnabled(_ uuid: CBUUID) {
        notificationsEnabled.insert(uuid)
        statusText = "Notify enabled: \(uuid.uuidString)"
        maybeStartHandshake()
    }

    func markHandshakeStepCompleted(for uuid: CBUUID) {
        if activeReadUUID == uuid {
            activeReadUUID = nil
            executeNextHandshakeRead()
        }
    }

    func updateBatteryStatus(from data: Data) {
        guard data.count >= 2 else { return }
        let level = Int(data[1])
        batteryPercent = level
        statusText = isCharging ? "Charging \(level)%" : "Battery \(level)%"
    }

    func updateChargeStatus(from data: Data) {
        guard data.count >= 2 else { return }
        isCharging = data[1] == 1
        if let batteryPercent {
            statusText = isCharging ? "Charging \(batteryPercent)%" : "Battery \(batteryPercent)%"
        } else {
            statusText = isCharging ? "Charging" : "Not charging"
        }
    }

    func updatePowerFromRead(_ data: Data) {
        guard data.count >= 2 else { return }
        batteryPercent = Int(data[0])
        isCharging = data[1] == 1
        if let batteryPercent {
            statusText = isCharging ? "Charging \(batteryPercent)%" : "Battery \(batteryPercent)%"
        }
    }

    func updateCliffState(_ data: Data) {
        guard data.count >= 4 else { return }
        cliffLeftFront = data[0] == 0
        cliffRightFront = data[1] == 0
        cliffLeftBack = data[2] == 0
        cliffRightBack = data[3] == 0
        evaluateSafetyInterlock()
    }

    func updateEvadeState(_ data: Data) {
        guard data.count >= 2 else { return }
        evadeLeft = Int(data[0])
        evadeRight = Int(data[1])
        evaluateSafetyInterlock()
    }

    func updateTouchState(side: UInt8, data: Data) {
        guard data.count >= 2 else { return }
        let touching = data[1] == 1
        if side == 0x09 {
            touchLeft = touching
        } else if side == 0x0A {
            touchRight = touching
        }
    }

    func updatePhoneAttachState(attached: Bool) {
        phoneAttached = attached
    }

    func updateTofState(_ data: Data) {
        guard data.count >= 2 else { return }
        let payload = Array(data.dropFirst())
        if payload.count >= 2 {
            let value16 = Int(payload[0]) | (Int(payload[1]) << 8)
            tofDistance = value16 > 0 ? value16 : Int(payload[0])
        } else {
            tofDistance = Int(payload[0])
        }
        evaluateSafetyInterlock()
    }

    func setSafetyInterlockEnabled(_ enabled: Bool) {
        safetyInterlockEnabled = enabled
        if !enabled {
            safetyInterlockActive = false
            return
        }
        evaluateSafetyInterlock()
    }

    func setObstacleThreshold(_ value: Int) {
        obstacleThreshold = min(max(value, 5), 200)
        evaluateSafetyInterlock()
    }

    func setPreemptiveMargin(_ value: Int) {
        preemptiveMargin = min(max(value, 0), 120)
        evaluateSafetyInterlock()
    }

    private func clearSensorState() {
        cliffLeftFront = false
        cliffRightFront = false
        cliffLeftBack = false
        cliffRightBack = false
        evadeLeft = nil
        evadeRight = nil
        touchLeft = false
        touchRight = false
        phoneAttached = nil
        tofDistance = nil
        fusedObstacleDistance = nil
    }

    private func evaluateSafetyInterlock() {
        let cliffDanger = cliffLeftFront || cliffRightFront || cliffLeftBack || cliffRightBack

        var candidates: [Int] = []
        if let left = evadeLeft { candidates.append(left) }
        if let right = evadeRight { candidates.append(right) }
        if let tof = tofDistance { candidates.append(tof) }
        fusedObstacleDistance = candidates.min()

        let activeThreshold = obstacleThreshold + (forwardSpeed > 0 ? preemptiveMargin : 0)
        let obstacleDanger = (fusedObstacleDistance ?? Int.max) <= activeThreshold

        let shouldStop = safetyInterlockEnabled && (cliffDanger || obstacleDanger)
        if shouldStop && !safetyInterlockActive {
            emergencyStop()
            let reason = cliffDanger ? "Cliff edge detected - you are near a table edge or drop" : "Obstacle too close at \(fusedObstacleDistance ?? 0)mm"
            statusText = cliffDanger ? "Safety stop: cliff detected" : "Safety stop: obstacle too close"
            onSafetyInterlockTriggered?(reason)
        }
        safetyInterlockActive = shouldStop
    }
}
