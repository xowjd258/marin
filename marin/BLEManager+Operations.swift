import CoreBluetooth
import Foundation

extension BLEManager {
    func smooth(_ current: Double, target: Double, alpha: Double) -> Double {
        current + ((target - current) * alpha)
    }

    func sendSequencePing() {
        guard let peripheral = selectedPeripheral,
              peripheral.state == .connected,
              let characteristic = writeCharacteristic else {
            statusText = "No writable characteristic found"
            return
        }

        let payload: [UInt8] = [0x00, 0x00, 0x01, 0xFF, 0x00, 0x01]
        let data = packetWithNextSequence(from: payload)
        write(data, to: characteristic, peripheral: peripheral)
        statusText = "Sequence ping sent"
    }

    func packetWithNextSequence(from template: [UInt8]) -> Data {
        guard !template.isEmpty else { return Data() }
        var packet = template
        packet[0] = nextSequence
        nextSequence &+= 1
        return Data(packet)
    }

    func sendStopKeepAlive() {
        guard let peripheral = selectedPeripheral,
              peripheral.state == .connected,
              let characteristic = writeCharacteristic else {
            return
        }

        let stopPayload: [UInt8] = [0x00, 0x00, 0x01, 0xFF, 0x00, 0x01]
        let data = packetWithNextSequence(from: stopPayload)
        write(data, to: characteristic, peripheral: peripheral)
    }

    func flushDriveCommand(force: Bool, dt: Double = 0.02) {
        guard let peripheral = selectedPeripheral,
              peripheral.state == .connected,
              let characteristic = discoveredCharacteristics[BLEUUIDs.move],
              isWritable(characteristic) else {
            return
        }

        if safetyInterlockActive {
            motionCoordinator.setDriveTargets(forward: 0, veer: 0)
            forwardSpeed = 0
            veerSpeed = 0

             filteredForwardByte = 0
             filteredVeerByte = 0

            let now = Date()
            let shouldSendHardStop: Bool
            if let lastDriveWriteAt {
                shouldSendHardStop = force || lastSentForward != 0 || lastSentVeer != 0 || now.timeIntervalSince(lastDriveWriteAt) >= 0.05
            } else {
                shouldSendHardStop = true
            }

            if shouldSendHardStop {
                write(Data([0x00, 0x00]), to: characteristic, peripheral: peripheral)
                lastSentForward = 0
                lastSentVeer = 0
                lastDriveWriteAt = now
                lastControlWriteAt = now
            }

            // Still flush head commands even when drive is interlocked
            if !isNodding {
                headAngle = motionCoordinator.step(dt: dt).head
            }
            let shouldSendHead = true
            if isNodding {
                flushNodStep(peripheral: peripheral, force: force)
            } else {
                flushHeadCommand(peripheral: peripheral, force: force, shouldSend: shouldSendHead)
            }
            return
        }

        let output = motionCoordinator.step(dt: dt)
        forwardSpeed = output.forward
        veerSpeed = output.veer
        if !isNodding {
            headAngle = output.head
        }

        let targetForwardByte = output.forward * 127.0
        let targetVeerByte = output.veer * 127.0
        filteredForwardByte = smooth(filteredForwardByte, target: targetForwardByte, alpha: 0.18)
        filteredVeerByte = smooth(filteredVeerByte, target: targetVeerByte, alpha: 0.18)

        let rawForward = Int8(filteredForwardByte.rounded())
        let rawVeer = Int8(filteredVeerByte.rounded())
        let nextForward: Int8
        let nextVeer: Int8
        let driveStepLimit: Int = 2
        let forwardDelta = Int(rawForward) - Int(lastSentForward)
        let veerDelta = Int(rawVeer) - Int(lastSentVeer)
        if abs(forwardDelta) > driveStepLimit {
            nextForward = Int8(Int(lastSentForward) + (forwardDelta > 0 ? driveStepLimit : -driveStepLimit))
        } else {
            nextForward = rawForward
        }
        if abs(veerDelta) > driveStepLimit {
            nextVeer = Int8(Int(lastSentVeer) + (veerDelta > 0 ? driveStepLimit : -driveStepLimit))
        } else {
            nextVeer = rawVeer
        }
        let now = Date()
        let keepAliveInterval: TimeInterval = 0.12
        let shouldRefreshSameCommand: Bool
        if let lastDriveWriteAt {
            shouldRefreshSameCommand = now.timeIntervalSince(lastDriveWriteAt) >= keepAliveInterval
        } else {
            shouldRefreshSameCommand = true
        }

        let shouldSendDriveThisTick = true
        if shouldSendDriveThisTick && (force || nextForward != lastSentForward || nextVeer != lastSentVeer || shouldRefreshSameCommand) {
            let payload = Data([UInt8(bitPattern: nextForward), UInt8(bitPattern: nextVeer)])
            write(payload, to: characteristic, peripheral: peripheral)
            lastSentForward = nextForward
            lastSentVeer = nextVeer
            lastDriveWriteAt = now
            lastControlWriteAt = now
        }

        let shouldSendHeadThisTick = true
        if isNodding {
            flushNodStep(peripheral: peripheral, force: force)
        } else {
            flushHeadCommand(peripheral: peripheral, force: force, shouldSend: shouldSendHeadThisTick)
        }

        if !isNodding, statusText == "Nodding" {
            statusText = "Session ready"
        }
    }

    func sendHeadSpeedCommand(_ speed: Int8, force: Bool) {
        guard let peripheral = selectedPeripheral,
              peripheral.state == .connected,
              let characteristic = discoveredCharacteristics[BLEUUIDs.clamp],
              isWritable(characteristic) else {
            return
        }

        let now = Date()
        if !force,
           let nodLastWriteAt,
           speed == nodCurrentSpeed,
           now.timeIntervalSince(nodLastWriteAt) < 0.08 {
            return
        }

        let payload = Data([0x00, UInt8(bitPattern: speed)])
        write(payload, to: characteristic, peripheral: peripheral)
        nodCurrentSpeed = speed
        nodLastWriteAt = now
    }

    func flushNodStep(peripheral: CBPeripheral, force: Bool) {
        guard !nodSteps.isEmpty else {
            sendHeadSpeedCommand(0, force: true)
            isNodding = false
            headCommandDirty = true  // Force position command to restore head angle
            statusText = "Session ready"
            return
        }

        let now = Date()
        if nodStepStartedAt == nil {
            nodStepStartedAt = now
            sendHeadSpeedCommand(nodSteps[0].speed, force: true)
            return
        }

        guard let nodStepStartedAt else { return }
        let currentStep = nodSteps[0]

        sendHeadSpeedCommand(currentStep.speed, force: force)

        if now.timeIntervalSince(nodStepStartedAt) >= currentStep.duration {
            nodSteps.removeFirst()
            self.nodStepStartedAt = now
            if let next = nodSteps.first {
                sendHeadSpeedCommand(next.speed, force: true)
            }
        }
    }

    func flushHeadCommand(peripheral: CBPeripheral, force: Bool, shouldSend: Bool) {
        guard shouldSend else { return }
        guard let characteristic = discoveredCharacteristics[BLEUUIDs.clamp], isWritable(characteristic) else {
            return
        }

        // headAngle is already smoothed by motionCoordinator (jerk-limited).
        // No additional smoothing here — just convert directly to BLE byte.
        let targetHeadByte = (1.0 - headAngle) * 255.0
        let rawHeadByte = UInt8(min(max(targetHeadByte.rounded(), 0), 255))
        let nextHeadByte: UInt8
        if let lastSentHeadByte {
            let maxDelta: Int = 8
            let delta = Int(rawHeadByte) - Int(lastSentHeadByte)
            if abs(delta) > maxDelta {
                let stepped = Int(lastSentHeadByte) + (delta > 0 ? maxDelta : -maxDelta)
                nextHeadByte = UInt8(min(max(stepped, 0), 255))
            } else {
                nextHeadByte = rawHeadByte
            }
        } else {
            nextHeadByte = rawHeadByte
        }
        let now = Date()
        let keepAliveInterval: TimeInterval = 0.14
        let shouldRefreshSameHead: Bool
        if let lastHeadWriteAt {
            shouldRefreshSameHead = now.timeIntervalSince(lastHeadWriteAt) >= keepAliveInterval
        } else {
            shouldRefreshSameHead = true
        }

        if !force, lastSentHeadByte == nextHeadByte, !shouldRefreshSameHead {
            return
        }

        write(Data([nextHeadByte]), to: characteristic, peripheral: peripheral)
        lastSentHeadByte = nextHeadByte
        lastHeadWriteAt = now
        lastControlWriteAt = now
        headCommandDirty = false
    }

    func write(_ data: Data, to characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let canWriteResponse = characteristic.properties.contains(.write)
        let writeType: CBCharacteristicWriteType = canWriteResponse ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    func updatePeripheralList() {
        peripherals = discoveredById.values.sorted { lhs, rhs in
            lhs.rssi > rhs.rssi
        }
    }

    func isLooiDevice(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let deviceName = peripheral.name ?? ""
        let nameCandidate = "\(localName) \(deviceName)".lowercased()

        if nameCandidate.contains("looi") {
            return true
        }

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            return serviceUUIDs.contains(BLEUUIDs.dpService)
        }

        return false
    }

    func isWritable(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
    }

    func canRead(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.read)
    }

    func isNotifiable(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }

    func startConnectionMaintenance() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(keepAliveTick), userInfo: nil, repeats: true)
    }

    func stopConnectionMaintenance() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    func startSessionLoop() {
        sessionLoopTimer?.invalidate()
        sessionLoopTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(sessionLoopTick), userInfo: nil, repeats: true)
    }

    func stopSessionLoop() {
        sessionLoopTimer?.invalidate()
        sessionLoopTimer = nil
    }

    func startDriveLoop() {
        driveLoopTimer?.invalidate()
        driveLoopTimer = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(driveLoopTick), userInfo: nil, repeats: true)
    }

    func stopDriveLoop() {
        driveLoopTimer?.invalidate()
        driveLoopTimer = nil
    }

    func maybeStartHandshake() {
        guard activeReadUUID == nil else { return }
        guard BLEUUIDs.requiredNotify.isSubset(of: notificationsEnabled) else { return }

        if pendingHandshakeReads.isEmpty {
            pendingHandshakeReads = BLEUUIDs.handshakeReadOrder
        }
        executeNextHandshakeRead()
    }

    func executeNextHandshakeRead() {
        guard activeReadUUID == nil else { return }
        guard let peripheral = selectedPeripheral, peripheral.state == .connected else { return }

        guard !pendingHandshakeReads.isEmpty else {
            if !isSessionReady {
                isSessionReady = true
                statusText = "Session ready"
                startSessionLoop()
            }
            return
        }

        let uuid = pendingHandshakeReads.removeFirst()
        guard let characteristic = discoveredCharacteristics[uuid], canRead(characteristic) else {
            executeNextHandshakeRead()
            return
        }

        activeReadUUID = uuid
        peripheral.readValue(for: characteristic)
        statusText = "Handshake read: \(uuid.uuidString)"
    }

    func scheduleReconnect(for peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        guard shouldAutoReconnect else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.shouldAutoReconnect else { return }
            self.statusText = "Reconnecting to \(peripheral.name ?? "device")..."
            self.central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    func resetCharacteristicState() {
        writeCharacteristic = nil
        discoveredCharacteristics.removeAll()
        notificationsEnabled.removeAll()
        pendingHandshakeReads.removeAll()
        activeReadUUID = nil
        pendingServiceDiscoveryCount = 0
    }

    @objc
    func keepAliveTick() {
        guard let peripheral = selectedPeripheral, peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    @objc
    func sessionLoopTick() {
        guard isSessionReady else { return }
        sendStopKeepAlive()
        if let powerCharacteristic = discoveredCharacteristics[BLEUUIDs.power],
           canRead(powerCharacteristic),
           let peripheral = selectedPeripheral,
           peripheral.state == .connected {
            peripheral.readValue(for: powerCharacteristic)
        }
    }

    @objc
    func driveLoopTick() {
        flushDriveCommand(force: false, dt: 0.02)
    }
}
