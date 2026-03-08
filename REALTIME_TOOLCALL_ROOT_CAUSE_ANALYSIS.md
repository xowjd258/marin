# Realtime Tool Call Failure Analysis (Marin)

## Scope

This document analyzes why tool/function calling appears unreliable in Marin realtime mode, even when session connection succeeds.

It focuses on current runtime flow in:

- `marin/marin/Agent/RealtimeAgentClient.swift`
- `marin/marin/Agent/RealtimeEventParser.swift`
- `marin/marin/Agent/RealtimeAudioIO.swift`
- `marin/marin/Agent/RobotExecutive.swift`
- `marin/marin/BLEManager.swift`

and compares observed behavior with a working reference flow in:

- `/Users/tjkim/aiapp/components/modal/RealTimeModal.tsx`

## Observed Symptoms

- Realtime connects successfully (`session.created`, `session.updated`).
- Audio response arrives (`response.output_audio.delta`), but tool actions are inconsistent.
- Robot may not move on commands like "move forward".
- Audio can feel overlapping/competing under certain conditions.
- Prior crashes occurred in audio engine lifecycle and format mismatch paths.

## Expected Tool Call Path

1. Client sends `session.update` with tool definitions.
2. User speech audio is appended; server VAD detects end of turn.
3. Model emits function call events:
   - `response.output_item.added` (function item)
   - `response.function_call_arguments.delta`
   - `response.function_call_arguments.done`
4. Client executes tool locally.
5. Client sends `conversation.item.create` with `function_call_output`.
6. Client sends `response.create` to continue.
7. Robot actuator path executes (`RobotExecutive` -> `BLEManager`).

## Current Marin Runtime Path

### Session/Tools

- On `session.created`, Marin sends `session.update` including:
  - modalities,
  - instructions,
  - VAD config,
  - audio formats,
  - tools (`set_emotion`, `drive`, `nod`, `stop`).
- On `session.updated`, Marin auto-starts voice streaming.

### Tool Event Handling

- Marin parses:
  - `response.output_item.added`
  - `response.function_call_arguments.delta`
  - `response.function_call_arguments.done`
- On `done`, Marin executes function and returns `function_call_output` then `response.create`.

### Motion Execution

- `drive` function maps to `RobotExecutive.applyDrive(...)`.
- `applyDrive` maps to `BLEManager.setForward/setVeer`.
- Safety interlock can force forward/veer to zero or trigger emergency stop.

## Likely Root Causes (Ranked)

## 1) Turn Contention From Camera Frame Injection (Highest)

Marin currently sends camera frame messages during streaming:

- `updateVisionFrameDataURL` -> `sendVisionFrameIfStreaming`
- Emits `conversation.item.create` with image + text while voice turn is active.

Impact:

- Additional user items enter conversation during active speech/response cycle.
- Model can start or bias responses around camera updates rather than user command intent.
- Tool decision consistency drops because a single command turn is no longer isolated.

This is a strong candidate for:

- "tool not being called" perception,
- multiple response streams / audio competition.

## 2) Tool Choice Not Enforced (High)

Current session config provides tools and instruction text, but does not hard-force tool invocation mode.

Impact:

- Model may produce spoken natural language output instead of function call events.
- UI then shows `response.output_audio.delta` without `function_call.*`.

This matches observed state where audio is present but no motion action is executed.

## 3) Event Surface Variance in Realtime Streams (Medium-High)

Function-call event surfaces can vary across versions/providers and response shapes.
Marin parses key events, but misses some possible alternates (for example output-item completion variants carrying function payload context).

Impact:

- If server emits a valid but unhandled function-call representation, Marin appears to "lose" tool calls.

External signals:

- Public Azure Q&A reports exist for inconsistent realtime function-call delta behavior compared with direct OpenAI paths.

## 4) Safety Interlock Suppression Misread as Tool Failure (Medium)

`BLEManager` safety path can suppress motion immediately:

- `setForward` clamps to zero when `safetyInterlockActive`.
- `evaluateSafetyInterlock` can call `emergencyStop`.

Impact:

- Tool call may execute correctly but robot still does not move.
- Appears as "tool not called" from user perspective.

## 5) Multi-Response Audio Concurrency (Medium)

Marin now filters playback by `activeResponseID`, but response generation can still overlap due to:

- automatic VAD responses,
- camera-injected conversation items,
- follow-up `response.create` after tool output.

Impact:

- Perceived simultaneous voices/competing output.
- Harder to correlate one user command to one tool action.

## 6) Argument/Enum Mismatch Edge Cases (Low-Medium)

Example:

- tool schema emotion enum includes `sleepy` while app enum uses `sleeping`.

Impact:

- Some tool calls may run with partial failure (`unknown emotion`) while other actions proceed.
- Not primary for movement failure, but contributes to instability perception.

## 7) Intent Fallback Path Interference (Low)

Marin includes text/transcript fallback routing (`routeTextToExecutive`) alongside explicit function call handling.

Impact:

- Mixed control mode can produce non-deterministic execution ordering if both paths trigger in the same interaction window.

## Comparison With Working aiapp Pattern

`aiapp` reference uses a simpler function-call loop:

1. Configure tools after datachannel open.
2. Wait for `response.function_call_arguments.done`.
3. Execute local tool.
4. Send `function_call_output` and `response.create`.

Key differences from Marin:

- No continuous camera conversation item injection during voice turns.
- Less multimodal concurrency competing with core tool loop.
- Tool loop and event handling are isolated and straightforward.

This strongly supports contention and complexity as principal causes in Marin.

## Input/Output Failure Scenarios

## Scenario A: Audio response without tool call

Input:

- User says "move forward".

Observed output:

- `response.output_audio.delta` only, no `function_call.done`.

Interpretation:

- Model selected direct spoken response path; tool call not emitted.

## Scenario B: Tool call emitted but no movement

Input:

- Function call `drive(forward>0, veer=0, duration_ms=...)`.

Observed output:

- Status may show drive execution, robot remains still.

Interpretation:

- Safety interlock active, motion suppressed post-tool execution.

## Scenario C: Multiple overlapping outputs

Input:

- Active voice stream + frequent camera frames.

Observed output:

- Competing audio/responses, inconsistent tool triggering.

Interpretation:

- Multiple user items/responses overlap; turn-level determinism lost.

## Confidence Summary

- High confidence: camera-turn contention + non-forced tool behavior are primary contributors.
- Medium confidence: event surface variance contributes in Azure realtime paths.
- Medium confidence: safety interlock explains part of "no movement" reports.

## What This Analysis Explains

- Why connection can be healthy while tool behavior is unreliable.
- Why voice output can exist without motion.
- Why movement failures can happen even when tool logic is present.
- Why output can sound like multiple channels speaking at once.

## What This Analysis Does Not Claim

- It does not prove Azure service-side fault in every case.
- It does not claim tool registration is absent (tools are registered).
- It does not claim a single root cause; this is a multi-factor runtime contention issue.
