import CoreBluetooth

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothReady = true
            statusText = "Bluetooth ready"
            if autoScanConnectEnabled, connectedDeviceName == nil, selectedPeripheral == nil {
                startScan()
            }
        case .poweredOff:
            handleBluetoothUnavailable("Bluetooth is off")
        case .unauthorized:
            handleBluetoothUnavailable("Bluetooth permission denied")
        case .unsupported:
            handleBluetoothUnavailable("Bluetooth unsupported")
        case .resetting:
            isBluetoothReady = false
            statusText = "Bluetooth resetting"
        case .unknown:
            isBluetoothReady = false
            statusText = "Bluetooth state unknown"
        @unknown default:
            isBluetoothReady = false
            statusText = "Bluetooth state unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoverResult(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "Unknown error"
        statusText = "Failed to connect: \(reason)"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "Disconnected"
        didDisconnect(peripheral, reason: reason)
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            statusText = "No services discovered"
            return
        }

        pendingServiceDiscoveryCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            statusText = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            discoveredCharacteristics[characteristic.uuid] = characteristic
        }

        for characteristic in characteristics where BLEUUIDs.requiredNotify.contains(characteristic.uuid) && isNotifiable(characteristic) {
            peripheral.setNotifyValue(true, for: characteristic)
        }

        if let preferred = characteristics.first(where: { $0.uuid == BLEUUIDs.sequence && isWritable($0) }) {
            writeCharacteristic = preferred
            statusText = "Sequence write ready (\(preferred.uuid.uuidString))"
        }

        if writeCharacteristic == nil, let fallback = characteristics.first(where: { isWritable($0) }) {
            writeCharacteristic = fallback
            statusText = "Write characteristic ready (\(fallback.uuid.uuidString))"
        }

        pendingServiceDiscoveryCount -= 1
        if pendingServiceDiscoveryCount <= 0 {
            maybeStartHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusText = "Notify setup failed (\(characteristic.uuid.uuidString)): \(error.localizedDescription)"
            return
        }

        if characteristic.isNotifying {
            markNotifyEnabled(characteristic.uuid)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusText = "Read/notify failed (\(characteristic.uuid.uuidString)): \(error.localizedDescription)"
            markHandshakeStepCompleted(for: characteristic.uuid)
            return
        }

        markHandshakeStepCompleted(for: characteristic.uuid)

        if characteristic.uuid == BLEUUIDs.notify, let data = characteristic.value, !data.isEmpty {
            switch data[0] {
            case 0x01:
                updateCliffState(Data(data.dropFirst()))
            case 0x02:
                updateEvadeState(Data(data.dropFirst()))
            case 0x05:
                updatePhoneAttachState(attached: true)
            case 0x06:
                updatePhoneAttachState(attached: false)
            case 0x08:
                updateBatteryStatus(from: data)
            case 0x09, 0x0A:
                updateTouchState(side: data[0], data: data)
            case 0x0B:
                updateChargeStatus(from: data)
            case 0x0E:
                updateTofState(data)
            default:
                break
            }
        }

        if characteristic.uuid == BLEUUIDs.power, let data = characteristic.value {
            updatePowerFromRead(data)
        }

        if characteristic.uuid == BLEUUIDs.cliff, let data = characteristic.value {
            updateCliffState(data)
        }

        if characteristic.uuid == BLEUUIDs.evade, let data = characteristic.value {
            updateEvadeState(data)
        }

        if characteristic.uuid == BLEUUIDs.stick, let data = characteristic.value, !data.isEmpty {
            updatePhoneAttachState(attached: data[0] == 1)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            statusText = "RSSI read failed: \(error.localizedDescription)"
            return
        }

        if let index = peripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
            peripherals[index].rssi = RSSI.intValue
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusText = "Write failed (\(characteristic.uuid.uuidString)): \(error.localizedDescription)"
        }
    }
}
