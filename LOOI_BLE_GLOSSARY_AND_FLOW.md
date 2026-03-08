# LOOI BLE Glossary and App Flow

## 1) Key Terms

### BLE Basics

- **BLE (Bluetooth Low Energy)**: Low-power Bluetooth protocol used for robot control.
- **Central**: The controller side. In this project, the iPhone app (`marin`).
- **Peripheral**: The controlled side. In this project, the LOOI robot.
- **Service**: A grouped capability area in BLE.
- **Characteristic**: A readable/writable/notifiable BLE data endpoint.
- **UUID**: Unique identifier for BLE services/characteristics.

### BLE Communication Modes

- **Read**: App requests current value from device.
- **Write**: App sends command or data to device.
- **Notify/Indicate**: Device pushes updates back to app.

### Session and Reliability

- **Handshake**: Initial sequence after connect to prepare a valid session.
- **Session Keep-Alive**: Periodic communication to keep connection/session active.
- **Auto Reconnect**: Reconnect attempt after unexpected disconnect.
- **RSSI**: Signal strength indicator used for link quality monitoring.

### Control Concepts

- **Sequence Channel**: Command path where actions can feel queued.
- **Realtime Channel**: Command path used for immediate control response.
- **Queueing**: Multiple commands stack and execute in order.
- **Latest-Wins**: Only newest command is sent/effective.
- **Control Loop**: Fixed-rate update loop that computes and sends outputs.
- **dt**: Time step per loop tick.

### Motion/Robotics Terms

- **Position (pos)**: Current command/state value.
- **Velocity (vel)**: Rate of change of position.
- **Acceleration (acc)**: Rate of change of velocity.
- **Jerk**: Rate of change of acceleration.
- **Jerk-Limited**: Motion update constrained to avoid harsh changes.
- **Minimum-Jerk Trajectory**: Smooth trajectory minimizing jerk over time.
- **Trajectory**: Time-based path of target values.
- **Interpolation / Spline**: Smoothly connecting values over time.
- **Deadband**: Ignore tiny inputs to reduce jitter/noise.
- **Clamp / Saturation**: Force values to remain within safe bounds.
- **State Machine**: Explicit phases with clear transition rules.
- **Blending**: Combining multiple motion sources using weights.
- **Gain**: Scaling factor applied to input/output.

### Planning Terms

- **OTG (Online Trajectory Generation)**: Real-time trajectory update while running.
- **TOPP (Time-Optimal Path Parameterization)**: Assigning timing along a path under limits.

---

## 2) Marin App End-to-End Process

### A. App Boot

1. `marinApp` launches and shows `ContentView`.
2. `ContentView` creates `BLEManager`.
3. `BLEManager` initializes `CBCentralManager` and starts Bluetooth state tracking.

### B. Bluetooth State Handling

1. `centralManagerDidUpdateState` reports Bluetooth status.
2. If `.poweredOn`, scanning is allowed (`Bluetooth ready`).
3. If unauthorized/off/unsupported, app updates status text and blocks scan/connect.

### C. Scan and Device Discovery

1. User taps `Start Scan`.
2. App calls `scanForPeripherals`.
3. `didDiscover` receives nearby devices.
4. App filters devices to LOOI candidates and updates discovered list.

### D. Connect and BLE Setup

1. User taps `Connect` on a discovered LOOI device.
2. App resets internal connection/session state.
3. `central.connect` starts connection.
4. On success (`didConnect`):
   - peripheral delegate is set
   - required services are discovered
   - maintenance loops are prepared

### E. Service/Characteristic Discovery

1. App discovers target services (DP + info).
2. App discovers characteristics under each service.
3. App caches writable/readable/notifiable characteristics.
4. App enables notify on required characteristics.

### F. Handshake

1. After required notify channels are active, handshake begins.
2. App runs ordered read sequence for device/session readiness.
3. When completed, app sets session status to ready.

### G. Runtime Control Loops

When session is ready, periodic loops run:

1. **Session loop**: sends keep-alive style packets.
2. **Power/battery loop**: reads battery-related characteristic.
3. **Drive loop**: sends realtime drive command with latest-wins logic.

### H. User Control Actions

- **Drive**
  - `Forward` slider controls forward/backward command.
  - `Veer` slider controls turning command.
  - `Stop` sends neutral command.
- **Light**
  - `Light On/Off` writes light characteristic.
- **Head**
  - `Angle` slider writes head position.
  - `Nod` runs a predefined nod motion sequence.

### I. Notify/Read Feedback

1. Device notify/read callbacks are processed.
2. Status text is updated (e.g., battery, errors, readiness).
3. RSSI updates refresh signal quality data.

### J. Disconnect and Recovery

- **Manual disconnect**
  - User taps `Disconnect`.
  - App stops loops and cancels peripheral connection.

- **Unexpected disconnect**
  - App handles `didDisconnect`.
  - If auto reconnect is enabled, app schedules reconnect attempt.

---

## 3) Practical Summary

Marin works as a staged pipeline:

**Scan -> Connect -> Discover -> Notify + Handshake -> Session Ready -> Realtime Control -> Disconnect/Recover**

This structure is why stable control depends on both BLE link quality and proper session protocol execution.
