# Voice Agent -> Face/Audio/Motion Integrated Design

## Goal

Connect the full runtime pipeline in Marin:

- Input (mic/audio, optional image frame)
- Agent (`gpt-realtime-1.5` on Azure Realtime)
- Robot output channels (face expression, sound, drive, head nod)
- Safety-first arbitration with BLE control loop

This design explicitly reuses existing LOOI resources (emotion/motion/audio codes) and existing downloaded audio assets.

## Constraints and Reuse Strategy

- Reuse existing BLE stack and safety interlock in `marin/marin/BLEManager.swift`.
- Reuse sound assets in `marin/marin/Resources/Audio`.
- Reuse LOOI code system from resource catalogs (`Resource.json`, behavior/event mappings) through a local manifest.
- Keep safety path deterministic and independent from cloud/LLM state.

## Runtime Planes

### 1) Realtime Plane (always on)

- BLE sensor ingest (obstacle/cliff/battery/link)
- Safety guard and emergency stop
- Motion loop (latest-wins drive/head)
- Face render loop (60fps)

### 2) Interaction Plane (event-driven)

- Realtime WebSocket session with Azure (`gpt-realtime-1.5`)
- Streaming audio input/output
- Camera capture stream (front camera)
- Vision frame sampling for realtime context
- Local fast intents (stop/left/right/nod/light) bypassing LLM

### 3) Planning Plane (gated)

- Parse model output into `RobotIntent`
- Resolve to concrete actions using resource-code registry

## Proposed Modules

## Core

- `marin/marin/Agent/RealtimeAgentClient.swift`
  - Azure Realtime WebSocket session management
  - Send mic chunks, receive events (`session.created`, output text/audio/tool calls)

- `marin/marin/Agent/RealtimeEventParser.swift`
  - Convert low-level event JSON into typed events

- `marin/marin/Agent/RobotIntentRouter.swift`
  - Route local-fast intents vs agent intents
  - Priority arbitration with safety state

- `marin/marin/Agent/RobotExecutive.swift`
  - Execute intent bundles across channels in parallel
  - Emit `drive/head/face/audio` actions with TTL and cancellation

- `marin/marin/Vision/CameraCaptureManager.swift`
  - AVFoundation session lifecycle
  - Front camera frame stream + permission handling

- `marin/marin/Vision/VisionFrameSampler.swift`
  - Downsample/compress frames
  - Adaptive frame rate (idle low, interaction high)

- `marin/marin/Vision/UserStateEstimator.swift`
  - Basic local signals (face present, distance proxy, gaze direction proxy)
  - Emits lightweight context for local reactions even when cloud is delayed

## Face

- `marin/marin/Face/FaceEmotion.swift`
- `marin/marin/Face/FaceState.swift`
- `marin/marin/Face/FaceAnimator.swift`
- `marin/marin/Face/RobotFaceView.swift`

The emotion names should align with existing HTML reference and LOOI emotion categories:

- neutral, happy, angry, sad, scared, surprised, love, sleepy, wink, dizzy

## Audio

- `marin/marin/Audio/AudioResourceRegistry.swift`
  - Map logical cue -> resource code -> local file path
- `marin/marin/Audio/AudioCuePlayer.swift`
  - Play `mp3/wav` from `Resources/Audio`
  - Supports one-shot effect, background loop, interrupt stop

## Motion/BLE

- Keep current `BLEManager` as actuator gateway.
- Add high-level calls:
  - `applyDrive(forward:veer:ttl:)`
  - `applyHead(angle:)`
  - `triggerNod(style:)`
  - `emergencyStop()`

## Data Contracts

## 1) Agent -> Executive Contract

```json
{
  "intent_id": "uuid",
  "priority": "normal",
  "emotion": { "name": "happy", "ttl_ms": 2200 },
  "voice": { "mode": "realtime_tts", "text": "좋아, 오른쪽으로 갈게." },
  "audio_cue": { "code": "018101", "optional": true },
  "motion": {
    "type": "drive",
    "forward": 0.25,
    "veer": 0.2,
    "duration_ms": 1800
  },
  "head": { "type": "nod", "style": "soft" }
}
```

## 1-1) Vision Context Contract (local -> agent)

```json
{
  "camera": {
    "face_present": true,
    "attention": "looking_at_robot",
    "distance": "near|mid|far",
    "gesture": "none|wave|thumbs_up",
    "frame_ref": "optional-inline-image"
  }
}
```

## 2) Safety Override Contract

```json
{
  "override": true,
  "reason": "cliff|obstacle|manual_stop",
  "forced_actions": ["drive_stop", "head_stop"],
  "face": "scared"
}
```

## Resource Reuse Mapping

## 1) Audio

- Primary source: `marin/marin/Resources/Audio/*.mp3|*.wav`
- Mapping source seed: `AUDIO_MANIFEST.json`
- Runtime lookup:
  - explicit code (e.g., `018101`) -> `<code>.mp3|wav`
  - fallback to semantic alias table (`bluetooth_connected`, `game_jump`, etc.)

## 2) Face/UI

- Preserve visual motion language from `marin_face_ref.html`
  - eyelid transforms
  - gaze offsets
  - overlay effects (hearts/zzz)
- Replace HTML DOM logic with SwiftUI state + `TimelineView` animation clock

## 3) Motion

- Keep BLE realtime channel as authoritative actuator path
- Agent emits abstract motion goals, Executive translates to BLE targets

## Priority and Arbitration

Order of execution authority:

1. Safety interlock / emergency stop
2. User interrupt command (local)
3. Fast local intent
4. Camera-driven local reflex (look-at, greet, attention cue)
5. Agent intent bundle
5. Idle/autonomous behavior

Rules:

- Any safety trigger cancels active motion intents immediately.
- Face/audio may continue briefly under safety only if non-blocking and explicitly allowed.
- New high-priority intent preempts lower-priority TTL actions.
- Camera reflex actions must remain bounded (short TTL) and never bypass safety rules.

## Failure and Degradation

- Realtime disconnect:
  - keep BLE/safety/face loops alive
  - switch voice pipeline to local intent-only mode
- Camera unavailable/permission denied:
  - keep voice-only interaction path active
  - disable vision-conditioned prompts and reflexes
- Audio decode failure:
  - skip cue, keep motion/face execution
- Unknown emotion/motion code:
  - map to neutral + no-op motion

## Implementation Phases

## Phase A: Integration Skeleton

- Add Realtime client and event parser
- Add Executive with no-op handlers
- Wire UI debug panel for event stream

## Phase B: Face + Audio Reuse

- Implement native face engine with emotion state transitions
- Implement code-based audio cue playback from `Resources/Audio`

## Phase C: Full Action Bundle

- Connect agent intent -> BLE drive/head/nod + face + audio parallel execution
- Add cancellation/preemption and TTL behavior

## Phase C-1: Camera Realtime Interaction

- Add camera permission, preview, and frame sampling
- Inject vision context into realtime turns
- Implement local camera reflexes (face found -> attention emotion, user wave -> short greet)

## Phase D: Safety Hardening

- Verify emergency stop latency and behavior under active agent tasks
- Add trace logs and replayable intent/sensor timeline

## Initial Validation Checklist

- Realtime handshake success (`101`, `session.created`)
- Local fast intent stop latency < 150 ms
- Safety interlock stop emission < 60 ms
- Emotion switch visible < 100 ms
- Audio cue and head nod synchronize within 200 ms target window
