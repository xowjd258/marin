# Marin Robot Agent Architecture and Implementation Plan

## 1. Purpose

This document defines a production-oriented architecture for Marin to support:

- Always-on operation (24/7 standby)
- Low-latency interaction (speak + move with minimal delay)
- Multimodal output channels
  - Emotion (event-driven)
  - Voice (optional, event-driven)
  - Motion (continuous, real-time)
- Safety-first autonomous behavior
- Migration of `marin_face_ref.html` to a fully native Swift/SwiftUI face engine

---

## 2. Product Requirements

### 2.1 Functional

- Robot can move continuously while speaking and showing emotion.
- Robot can execute autonomous behavior (roam, avoid obstacles, recover route).
- Robot can react to user interrupt commands (e.g., "stop") immediately.
- Robot exposes sensor and safety state in UI.

### 2.2 Non-Functional

- No continuous LLM streaming for idle standby (cost control).
- Deterministic safety response regardless of LLM/network state.
- Graceful degradation under weak network/cloud failure.
- Smooth motion without command queue artifacts.

### 2.3 Latency Targets

- Local interrupt command to motion reaction: < 150 ms
- Safety interlock to hard stop command emission: < 60 ms
- Partial ASR to fast intent dispatch: < 200 ms
- Face emotion update after event: < 100 ms

---

## 3. System Architecture

## 3.1 Runtime Planes

### Realtime Plane (always active, local)

- BLE sensor ingestion
- Safety guard and interlock
- Continuous motion control loop
- Face animation/rendering loop

### Interactive Plane (event-driven)

- Voice capture (VAD + ASR partial/final)
- Fast intent routing (local)
- Optional TTS

### Planning Plane (asynchronous, gated)

- Agent/LLM for complex instructions only
- Plan parsing into executable robot skills/goals

## 3.2 Control Priority

1. Safety guard (highest)
2. User interrupt / emergency stop
3. Fast local intents
4. Planner tasks
5. Idle autonomous roam

---

## 4. Behavioral Model

## 4.1 Core State Machine

- `Idle`
- `Listening`
- `ExecutingTask`
- `AutonomousRoam`
- `SafetyOverride`
- `Recovering`

Example transitions:

- `ExecutingTask -> SafetyOverride` on cliff/obstacle threshold breach
- `SafetyOverride -> Recovering` after hazard clears
- `Recovering -> ExecutingTask` if resumable task exists
- `Any -> Idle` on explicit stop/cancel

## 4.2 Behavior Tree (Executive)

- `Root`
  - `SafetyGuardNode`
  - `PrioritySelector`
    - `UserInterruptNode`
    - `TaskExecutionNode`
    - `AutonomousRoamNode`

`TaskExecutionNode` may run parallel branches:

- motion branch (continuous)
- voice branch (one-shot)
- emotion branch (one-shot or TTL-based)

---

## 5. Data Contracts

## 5.1 Agent Output Contract

```json
{
  "emotion": { "style": "friendly", "ttl_ms": 2500 },
  "voice": { "enabled": true, "text": "알겠어, 이쪽으로 갈게." },
  "motion": {
    "mode": "goto_or_avoid",
    "continuous": true,
    "params": {
      "speed": 0.35,
      "prefer_right_turn": true,
      "timeout_s": 30
    }
  }
}
```

## 5.2 Realtime Control Contract

```json
{
  "forward": 0.28,
  "veer": -0.12,
  "head": 0.74,
  "safety_override": false
}
```

---

## 6. Native Face Engine (HTML to Swift Migration)

## 6.1 Why migrate from HTML

- Avoid WKWebView bridge latency and synchronization complexity
- Keep rendering and robot state on same native update cycle
- Improve long-running stability for always-on operation

## 6.2 Mapping from `marin_face_ref.html`

- Emotion classes (`e-neutral`, `e-happy`, etc.) -> `FaceEmotion` enum
- Eye ball / shadow position -> gaze vectors in `FaceState`
- Lid transform/clip behavior -> parametric eyelid paths in `EyeView`
- Effects (`hearts`, `zzz`, tremble/sway) -> SwiftUI overlays + animation states

## 6.3 Face Module Components

- `FaceEmotion.swift`
  - enum of supported expressions
- `FaceState.swift`
  - gaze, blink, speaking energy, emotion, accent flags
- `FaceParameters.swift`
  - emotion-specific shape/color coefficients
- `FaceAnimator.swift`
  - tick update: blink, saccade, micro-motion, emotion transitions
- `EyeView.swift`
  - left/right eye rendering primitive
- `RobotFaceView.swift`
  - full face scene composition
- `FaceEffectsView.swift`
  - hearts/zzz/dizzy overlays
- `FaceViewModel.swift`
  - external event binding and TTL handling

## 6.4 Face Update Policy

- Render loop: 60 FPS via `TimelineView(.animation)`
- Event updates:
  - Emotion: immediate + smooth interpolation
  - Speaking: energy envelope from TTS/ASR activity
  - Safety: temporary override emotion (e.g., `scared`)

---

## 7. Voice and Agent Strategy (Cost + Latency)

## 7.1 Fast Path (local, no LLM)

- Commands like stop/go/left/right/nod/light
- Routed by local intent parser
- Dispatched directly to Executive

## 7.2 Slow Path (LLM-gated)

- Complex, multi-step, or ambiguous instructions only
- Planner output converted to executable goals/skills
- LLM call gated by:
  - cooldown window
  - intent complexity threshold
  - duplicate request suppression

## 7.3 Always-On Policy

- 24/7 standby uses local VAD/KWS + local routing
- LLM not active continuously
- Cloud failures must not block core motion/safety

---

## 8. BLE and Motion Control Strategy

## 8.1 Motion

- Continuous loop at fixed rate (20-50 Hz)
- Controller maintains smooth target tracking
- Drive and head channels must be scheduled to prevent device-side overload

## 8.2 Safety

- Interlock uses fused sensing: cliff + evade + ToF
- Active interlock forces hard stop command path
- Safety override bypasses planner and user macro tasks

## 8.3 Reliability

- Channel-aware write scheduling
- Keepalive policy for drive stability
- Backpressure-aware queue for command bursts

---

## 9. Proposed Code Structure

```text
marin/
  marin/
    App/
      MarinApp.swift
      AppContainer.swift
      AppStore.swift

    Core/
      Models/
        AgentOutput.swift
        MotionGoal.swift
        VoicePlan.swift
        SafetyState.swift

      EventBus/
        RobotEvent.swift
        EventBus.swift

      Executive/
        ExecutiveEngine.swift
        BehaviorTree.swift
        nodes/
          SafetyGuardNode.swift
          UserInterruptNode.swift
          DriveNode.swift
          NodNode.swift
          RoamNode.swift
          AvoidNode.swift
          SpeakNode.swift

      Motion/
        MotionCoordinator.swift
        LocomotionController.swift
        HeadController.swift
        AvoidanceController.swift

      BLE/
        BLEManager.swift
        BLEManager+Delegates.swift
        BLEManager+Operations.swift
        BLECommandQueue.swift

      Voice/
        VoiceInputManager.swift
        IntentRouter.swift
        TTSManager.swift

      Agent/
        AgentGateway.swift
        PromptBuilder.swift
        PlanParser.swift

    Face/
      FaceEmotion.swift
      FaceState.swift
      FaceParameters.swift
      FaceAnimator.swift
      FaceViewModel.swift
      EyeView.swift
      RobotFaceView.swift
      FaceEffectsView.swift

    UI/
      DashboardView.swift
      FacePanelView.swift
      ConnectionSectionView.swift
      SensorSectionView.swift
      DriveSectionView.swift
      HeadSectionView.swift
      AgentSectionView.swift
```

---

## 10. Detailed Implementation Plan

## Phase 0 - Baseline Hardening (1-2 days)

- Stabilize current interlock enforcement and drive stop behavior.
- Add structured diagnostics for sensor triggers and command writes.

Deliverables:

- deterministic hard stop under interlock
- event log panel (interlock reason, command channel)

## Phase 1 - Native Face Engine MVP (2-4 days)

- Create `FaceEmotion`, `FaceState`, `FaceAnimator`, `RobotFaceView`.
- Reproduce neutral/happy/angry/sad/sleepy/love baseline from HTML ref.
- Replace any WebView-based face dependency.

Deliverables:

- native face rendering with blink + gaze + emotion transitions
- face panel integrated into dashboard

Acceptance:

- no WebView required
- emotion switch under 100 ms

## Phase 2 - Executive Skeleton (2-3 days)

- Introduce `ExecutiveEngine` and minimal BT nodes.
- Move direct control actions into node actions.
- Ensure safety node preempts all other nodes.

Deliverables:

- runnable BT with safety + manual control + idle behavior

Acceptance:

- interlock preemption verified during active task

## Phase 3 - Voice Fast Path (2-4 days)

- Add `VoiceInputManager` (VAD + partial ASR).
- Implement `IntentRouter` for immediate local commands.
- Optional `TTSManager` for short acknowledgments.

Deliverables:

- local low-latency command loop without LLM

Acceptance:

- stop/go command reaction < 200 ms in normal conditions

## Phase 4 - Agent-Gated Planning (2-4 days)

- Implement `AgentGateway`, `PromptBuilder`, `PlanParser`.
- Add planner call gate (cooldown, complexity, dedupe).
- Convert planner output to `MotionGoal` + optional voice/emotion cues.

Deliverables:

- complex instruction support without continuous LLM polling

Acceptance:

- repeated simple commands do not trigger planner calls

## Phase 5 - Autonomous Behaviors (3-5 days)

- Implement `RoamNode`, `AvoidNode`, `RecoverNode` patterns.
- Add blocked-path recovery and retry strategy.
- Add boredom/idle behavior scheduler.

Deliverables:

- autonomous roam + obstacle-aware reroute

Acceptance:

- robot can self-roam and recover from blocked path events

## Phase 6 - Tuning and Reliability (ongoing)

- Tune control loop frequencies and channel write rates.
- Add long-run soak tests (6h, 12h, 24h).
- Profile CPU/network/token usage and optimize.

Deliverables:

- stability report and tuned default parameters

---

## 11. Testing Strategy

## 11.1 Unit Tests

- intent routing
- planner output parsing
- safety threshold evaluation
- BT node transitions

## 11.2 Integration Tests

- sensor event -> interlock -> hard stop path
- voice fast path -> motion execution
- planner command -> BT execution chain

## 11.3 Soak Tests

- 24h idle standby
- 24h periodic command bursts
- network loss and recovery scenarios

## 11.4 HIL (Hardware-in-the-loop)

- obstacle and cliff real-world trigger tests
- continuous move + speak + emotion concurrency

---

## 12. Operational Safeguards

- Emergency stop command available at all times
- Interlock defaults ON
- Planner can be disabled without breaking core functionality
- Voice module optional mode supported (mute/selective)

---

## 13. Next Immediate Actions

1. Implement Phase 1 files (`FaceEmotion`, `FaceState`, `FaceAnimator`, `RobotFaceView`).
2. Wire face state updates from current BLE/safety events.
3. Add minimal Executive skeleton with safety-first tick order.
4. Introduce local fast intent router before LLM integration.

---

## 14. Agent / LLM Routing Policy (Codex 5.3)

This project should use `aicenter/gpt-5.3-codex` as the primary planner/reasoning model.

## 14.1 Model Roles

- `Primary planner model`: `aicenter/gpt-5.3-codex`
- `Small utility model`: `aicenter/kimi-k2.5` (optional fallback for low-cost, non-critical summarization)

## 14.2 Where Codex 5.3 is used

- Complex instruction decomposition into executable robot skill plans
- Recovery/replan logic when path is blocked repeatedly
- Context-aware response generation (voice text)
- Emotion policy suggestions (high-level style only)

## 14.3 Where Codex 5.3 must NOT be used

- Realtime control loops (20-50 Hz motion)
- Safety guard and interlock decisions
- Low-latency interrupt commands (stop/go/left/right)
- BLE packet timing and command scheduling

## 14.4 Runtime Routing Rules

1. Fast local intent first (no LLM).
2. If intent is simple and mappable to local skills, execute directly.
3. If intent is complex/multi-step/ambiguous, call `aicenter/gpt-5.3-codex`.
4. Convert model output to strict `AgentOutput` schema.
5. Execute via Executive; SafetyGuard retains top priority.

## 14.5 Suggested Planner Call Gate

- Cooldown per user intent type: 10-30 seconds
- Deduplicate near-identical requests
- Maximum planner timeout: 1.5-2.5 seconds (fallback to local policy if timeout)
- Cache recent task plans for short horizon reuse

## 14.6 Implementation Hooks

Add the following components under `Core/Agent/`:

- `ModelRouter.swift`
  - routes requests to `aicenter/gpt-5.3-codex` by policy
- `PlannerClient.swift`
  - OpenAI-compatible client wrapper for the configured provider
- `PlannerSchema.swift`
  - strict schema for parsing planner output into `AgentOutput`
- `PlannerPolicy.swift`
  - cooldown, dedupe, timeout, fallback rules

## 14.7 Reliability and Safety Notes

- Planner output is advisory, not authoritative.
- Executive validates all planner-generated actions before execution.
- Safety events immediately preempt planner tasks.

## 14.8 Security Note

If API keys/secrets are ever exposed in logs, chat, or files, rotate them immediately and move them to secure environment variable storage before production use.
