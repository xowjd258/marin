# marin

Marin is an iOS BLE controller app for LOOI Robot.  
This project focuses on reliable low-level BLE communication and a practical control UI for real hardware testing.

## Overview

Marin currently provides:

- BLE scan and filtering for LOOI-compatible devices only
- Connection lifecycle management (connect, disconnect, auto reconnect)
- Handshake and session keep-alive flow for stable control
- Realtime drive control (forward / veer)
- Head control (angle + nod gesture)
- Light on/off control

The app is written with SwiftUI + CoreBluetooth and is organized to keep BLE protocol logic separate from UI code.

## Current App Flow

1. Start scan from the app.
2. The app filters discovered peripherals and shows only LOOI candidates.
3. Connect to a device.
4. Marin discovers required services/characteristics and enables notify channels.
5. Marin executes handshake reads in order.
6. Session loops start:
   - sequence keep-alive ping
   - periodic power/battery reads
   - realtime drive command loop (latest-wins behavior)

## Controls

### Connection

- `Start Scan` / `Stop Scan`
- `Connect` from discovered device list
- `Disconnect` to end current BLE session intentionally
- `Send Test Command` for quick protocol ping

### Drive

- `Forward` slider: `+` forward, `-` backward
- `Veer` slider: turning bias
- `Stop` button: immediate neutral drive command
- `Light On/Off`

### Head

- `Angle` slider for head position
- `Nod` button for a soft nod sequence

## Architecture

### BLE Domain

- `marin/BLEUUIDs.swift`
  - BLE UUID constants
  - notify requirements
  - handshake read order

- `marin/BLEModels.swift`
  - shared model types such as `PeripheralItem`

- `marin/BLEManager.swift`
  - primary BLE state (`@Published` values)
  - high-level actions used by UI

- `marin/BLEManager+Operations.swift`
  - packet creation and write helpers
  - timers and loop operations
  - handshake orchestration
  - reconnect scheduling and utility functions

- `marin/BLEManager+Delegates.swift`
  - `CBCentralManagerDelegate`
  - `CBPeripheralDelegate`

### UI Domain

- `marin/ContentView.swift`
  - top-level composition only

- `marin/ConnectionSectionView.swift`
- `marin/DriveSectionView.swift`
- `marin/HeadSectionView.swift`
- `marin/DeviceListSectionView.swift`

Each section view is intentionally small and bound to `BLEManager` state/actions.

## Requirements

- macOS with Xcode installed
- Xcode 15+
- iPhone with Bluetooth enabled
- LOOI hardware powered on

## Permissions

The app needs Bluetooth usage permission in iOS.  
If scanning does not work, check:

- iOS Settings -> Privacy & Security -> Bluetooth -> `marin` is enabled
- Bluetooth is enabled globally on the phone

## Build

```bash
xcodebuild -project marin.xcodeproj -scheme marin -destination 'generic/platform=iOS' build
```

## Run on Device

1. Open `marin.xcodeproj` in Xcode.
2. Select your iPhone as run destination.
3. Build and run.
4. Accept Bluetooth permission prompt on first launch.
5. Put LOOI into pairing/advertising mode.
6. Scan -> Connect -> Control.

## Troubleshooting

### No devices shown

- Verify LOOI is powered on and advertising.
- Re-enter pairing mode on LOOI.
- Confirm iOS Bluetooth permission is granted.
- Fully close other apps that may be holding the same BLE session.

### Connects but disconnects often

- Keep LOOI close to the phone for initial tests.
- Confirm session reaches handshake-ready state in app status.
- Retry after disconnect using scan + reconnect.

### Commands feel delayed

- Use drive controls (`fed0` path) for realtime movement.
- Sequence-style commands may queue by design on device firmware.

## Development Notes

- This codebase is optimized for experimentation on real hardware.
- BLE protocol behavior can vary by firmware version.
- Prefer extending BLE manager modules instead of putting logic directly into SwiftUI views.
