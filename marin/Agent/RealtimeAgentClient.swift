import Combine
import Foundation
import os

private let agentLog = Logger(subsystem: "marin", category: "Agent")

@MainActor
final class RealtimeAgentClient: ObservableObject {
    enum ConnectionState: String {
        case idle = "Idle"
        case connecting = "Connecting"
        case connected = "Connected"
        case failed = "Failed"
    }

    @Published var state: ConnectionState = .idle
    @Published var statusText: String = "Realtime idle"
    @Published var lastEventType: String = "-"
    @Published var lastEventPreview: String = ""
    @Published var outputText: String = ""
    @Published var isVoiceStreaming: Bool = false
    @Published var lastErrorDetail: String = ""
    @Published var outputAudioBytes: Int = 0

    private let config = RealtimeAgentConfig()
    private weak var executive: RobotExecutive?
    private weak var faceAnimator: FaceAnimator?
    private weak var camera: CameraCaptureManager?
    private weak var ble: BLEManager?
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let audioIO = RealtimeAudioIO()
    private var latestVisionDataURL: String?
    private var cancellables = Set<AnyCancellable>()
    private var activeResponseID: String?
    private var pendingFunctionCalls: [String: (name: String, args: String)] = [:]
    private var lastVisionSentAt: Date = .distantPast
    private let visionSendInterval: TimeInterval = 10.0
    private var postOutputCooldownUntil: Date = .distantPast
    /// true while the server is generating a response (prevents sending response.create or conversation.item.create that would conflict)
    private var isResponseActive: Bool = false
    private var hadFunctionCallsInResponse: Bool = false
    /// true when we sent response.create ourselves (after function call results); prevents cooldown from cancelling it
    private var selfInitiatedResponsePending: Bool = false
    /// Pending movement function call that waits for onMovementCompleted before sending result
    private var pendingMovementCallID: String?
    /// Explore mode — AI-driven autonomous exploration loop
    private var exploreState: ExploreState?

    private struct ExploreState {
        let callID: String
        let goal: String
        var stepsUsed: Int = 0
        let maxSteps: Int = 20
        var callIDReturned: Bool = false
        let startedAt: Date = Date()
        let timeoutSeconds: TimeInterval = 180  // 3 minutes max
    }
    /// Auto-light: turn flashlight on when camera brightness is below threshold
    private var autoLightEnabled = true
    private var autoLightIsOn = false
    private let darkThreshold: Float = 0.08
    private let brightThreshold: Float = 0.15  // hysteresis to avoid flickering
    /// When the AI manually controls light, pause auto-light until this date
    private var autoLightPausedUntil: Date = .distantPast
    /// Suppress onMovementCompleted during obstacle back-up (handled separately)
    private var suppressMovementCompleted = false
    /// IDs of image-bearing conversation items — deleted when a new image is sent to keep context fresh
    private var imageItemIDs: [String] = []
    private var imageItemCounter: Int = 0
    /// Conversation memory manager — prunes old items and maintains structured summary
    private let memory = ConversationMemory()
    /// ID of the current memory summary item in the conversation
    private var memorySummaryItemID: String?
    /// Maps function call callID → server-assigned item ID for the function_call item
    private var callIDToServerItemID: [String: String] = [:]
    /// Server-assigned item ID for the current assistant audio response
    private var currentAssistantItemID: String?

    func bind(executive: RobotExecutive) {
        self.executive = executive
        audioIO.$receivedOutputBytes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bytes in
                self?.outputAudioBytes = bytes
            }
            .store(in: &cancellables)

        audioIO.onInputPCM16Chunk = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.sendInputAudioChunk(data)
            }
        }

        audioIO.onLoudInputDetectedDuringPlayback = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUserInterrupt()
            }
        }

        executive.onMovementCompleted = { [weak self] in
            self?.handleMovementCompleted()
        }
    }

    func bind(faceAnimator: FaceAnimator) {
        self.faceAnimator = faceAnimator
    }

    func bind(camera: CameraCaptureManager) {
        self.camera = camera
        camera.onBrightnessUpdated = { [weak self] brightness in
            self?.handleBrightnessUpdate(brightness)
        }
    }

    func bind(ble: BLEManager) {
        self.ble = ble
    }

    func interruptCurrentResponse() {
        audioIO.cancelPlaybackForInterrupt()
        activeResponseID = nil
        isResponseActive = false
        outputText = ""
        sendJSON(["type": "response.cancel"])
        faceAnimator?.onOutputAudioDone()
        if exploreState != nil {
            endExploration(reason: "User interrupted — exploration stopped")
        }
        statusText = "User interrupted"
    }

    private func handleUserInterrupt() {
        interruptCurrentResponse()
    }

    func notifySensorEvent(reason: String) {
        guard state == .connected, isVoiceStreaming else { return }
        if isResponseActive {
            sendJSON(["type": "response.cancel"])
            isResponseActive = false
        }
        // Cancel any pending movement since safety stop already fired
        if let callID = pendingMovementCallID {
            pendingMovementCallID = nil
            // Return error result for the blocked movement
            let fcoID = "fco_\(callID)"
            sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "id": fcoID,
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": "Movement blocked by safety: \(reason)"
                ]
            ])
            trackFunctionResult(callID: callID, name: "move", output: "Movement blocked by safety: \(reason)")
        }

        // Back up slightly, tilt head down, and capture what's in front
        agentLog.info("Obstacle detected — backing up and looking down to identify")
        suppressMovementCompleted = true
        executive?.moveDirection(angleDeg: 180, distanceCm: 8, speedCmPerSec: 10)
        executive?.headMove(angleDeg: -45, speed: "fast", repeats: 1)

        // After back-up settles, capture the obstacle image
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.suppressMovementCompleted = false
            var content: [[String: Any]] = []
            let isExploring = self.exploreState != nil
            let alertText: String
            if isExploring {
                alertText = "[OBSTACLE during exploration] \(reason). I backed up and looked down to see what's blocking me. Decide how to get around it — turn to avoid, or try a different direction. You can keep exploring."
            } else {
                alertText = "[OBSTACLE DETECTED] \(reason). I backed up and looked down. React with a surprised expression and describe what you see blocking your path."
            }
            if let dataURL = self.latestVisionDataURL {
                self.sendImageItem(label: alertText, dataURL: dataURL)
            } else {
                self.sendJSON([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": alertText]]
                    ]
                ])
            }
            // Restore head to level
            self.executive?.headMove(angleDeg: 0, speed: "normal", repeats: 1)
            self.selfInitiatedResponsePending = true
            self.sendJSON(["type": "response.create"])
        }
    }

    func updateVisionFrameDataURL(_ dataURL: String) {
        latestVisionDataURL = dataURL
        latestVisionTimestamp = Date()

        // If waiting for a fresh frame after movement, deliver it now
        if let continuation = pendingFreshFrameContinuation {
            pendingFreshFrameContinuation = nil
            continuation.resume(returning: dataURL)
        }
    }

    /// Timestamp of the most recent camera frame
    private var latestVisionTimestamp: Date = .distantPast
    /// Continuation waiting for a fresh post-movement frame
    private var pendingFreshFrameContinuation: CheckedContinuation<String?, Never>?

    /// Invalidate the current frame and wait for a fresh one (up to timeout).
    private func waitForFreshFrame(timeout: TimeInterval = 0.8) async -> String? {
        // Mark current frame as stale
        latestVisionDataURL = nil

        return await withCheckedContinuation { continuation in
            pendingFreshFrameContinuation = continuation

            // Timeout: if no new frame arrives, resume with nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let pending = self.pendingFreshFrameContinuation {
                    self.pendingFreshFrameContinuation = nil
                    // Return whatever we have (may still be nil)
                    pending.resume(returning: self.latestVisionDataURL)
                }
            }
        }
    }

    /// Delete previous image items from conversation to keep context fresh, then send a new one.
    private func sendImageItem(label: String, dataURL: String) {
        // Delete all previous image items from conversation history
        for oldID in imageItemIDs {
            sendJSON(["type": "conversation.item.delete", "item_id": oldID])
            memory.markDeletedFromServer(oldID)
        }
        imageItemIDs.removeAll()

        // Generate a unique client-side ID for this image item
        imageItemCounter += 1
        let itemID = "img_\(imageItemCounter)"
        imageItemIDs.append(itemID)

        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "id": itemID,
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": label],
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]
        ])
        memory.trackItem(id: itemID, type: .userImage, summary: label.prefix(60).description)
    }

    /// Track a function call result being sent to the server
    private func trackFunctionResult(callID: String, name: String, output: String) {
        let trackID = "fco_\(callID)"
        memory.trackItem(id: trackID, type: .functionResult(name: name, output: output), summary: "\(name) → \(output.prefix(50))")
    }

    /// Prune old conversation items if history is too long, injecting a memory summary
    private func pruneConversationIfNeeded() {
        guard let result = memory.pruneIfNeeded() else { return }

        // Delete old items from server conversation
        for itemID in result.itemIDsToDelete {
            sendJSON(["type": "conversation.item.delete", "item_id": itemID])
        }

        // Delete old memory summary if exists
        if let oldMemID = memorySummaryItemID {
            sendJSON(["type": "conversation.item.delete", "item_id": oldMemID])
        }

        // Inject new memory summary at current position
        let memID = "mem_\(Int(Date().timeIntervalSince1970))"
        memorySummaryItemID = memID
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "id": memID,
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": result.memorySummary]]
            ]
        ])
        memory.trackItem(id: memID, type: .systemMessage, summary: "memory summary")
    }

    /// Called when a move/turn physically completes — sends deferred function result + snapshot
    private func handleMovementCompleted() {
        if suppressMovementCompleted {
            suppressMovementCompleted = false
            return
        }
        guard state == .connected, isVoiceStreaming else { return }

        // Send the deferred function_call_output now that movement is done
        if let callID = pendingMovementCallID {
            pendingMovementCallID = nil
            agentLog.info("Movement completed — waiting for fresh frame before sending result for \(callID)")
            hadFunctionCallsInResponse = true

            let sensorSummary = buildShortSensorSummary()
            let isExploring = exploreState != nil
            let output = isExploring
                ? "ok — movement finished. \(sensorSummary) Keep exploring: decide your next action."
                : "ok — movement finished. \(sensorSummary)"

            // Send function result immediately so the server knows the call completed
            let fcoID = "fco_\(callID)"
            sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "id": fcoID,
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ]
            ])
            trackFunctionResult(callID: callID, name: "move", output: output)

            // Wait for a fresh camera frame, then inject snapshot and trigger response
            Task { @MainActor [weak self] in
                guard let self else { return }
                let freshDataURL = await self.waitForFreshFrame(timeout: 0.8)
                if let dataURL = freshDataURL {
                    let label = isExploring
                        ? "[Exploration view — this is what you see after moving]"
                        : "[Auto-captured after movement — this is what you see now from your new position]"
                    self.sendImageItem(label: label, dataURL: dataURL)
                }
                // Track explore steps and check limits
                if self.exploreState != nil {
                    self.exploreState!.stepsUsed += 1
                    if self.exploreState!.stepsUsed >= self.exploreState!.maxSteps {
                        self.endExploration(reason: "Maximum exploration steps reached (\(self.exploreState!.maxSteps)). Summarize what you found.")
                        self.selfInitiatedResponsePending = true
                        self.sendJSON(["type": "response.create"])
                        return
                    }
                    if self.checkExploreTimeout() {
                        self.selfInitiatedResponsePending = true
                        self.sendJSON(["type": "response.create"])
                        return
                    }
                }
                self.selfInitiatedResponsePending = true
                self.sendJSON(["type": "response.create"])
            }
        } else {
            // No pending call — wait for fresh frame then inject snapshot
            guard !isResponseActive else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let freshDataURL = await self.waitForFreshFrame(timeout: 0.8)
                if let dataURL = freshDataURL {
                    agentLog.info("Injecting fresh post-movement camera snapshot")
                    self.sendImageItem(label: "[Auto-captured after movement — this is what you see now from your new position]", dataURL: dataURL)
                }
            }
        }
    }

    // MARK: - Explore mode

    private func startExploration(callID: String, goal: String) {
        exploreState = ExploreState(callID: callID, goal: goal)
        agentLog.info("Exploration started — goal: \(goal)")
        statusText = "Exploring: \(goal)"

        // Return the function call result immediately so the AI can start deciding
        hadFunctionCallsInResponse = true
        let sensorSummary = buildShortSensorSummary()
        let fcoID = "fco_\(callID)"
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "id": fcoID,
                "type": "function_call_output",
                "call_id": callID,
                "output": "Exploration mode activated. Goal: \(goal). \(sensorSummary) You are now exploring autonomously. Use move/turn/look/head to navigate. Use stop_explore when done or goal is reached. Obstacles will be auto-detected — if blocked, you'll see what's in your way and can navigate around it. Start by looking around with look(), then decide where to go."
            ]
        ])
        trackFunctionResult(callID: callID, name: "explore", output: "Exploration started: \(goal)")
        exploreState?.callIDReturned = true
    }

    private func endExploration(reason: String) {
        guard let explore = exploreState else { return }
        agentLog.info("Exploration ended after \(explore.stepsUsed) steps — \(reason)")
        exploreState = nil
        statusText = "Exploration complete"

        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "[Exploration ended] \(reason). Steps used: \(explore.stepsUsed). Summarize what you discovered."]
                ]
            ]
        ])
    }

    private func nudgeExplorationAction() {
        guard let explore = exploreState else { return }
        // Check timeout
        if Date().timeIntervalSince(explore.startedAt) >= explore.timeoutSeconds {
            endExploration(reason: "Exploration timed out after \(Int(explore.timeoutSeconds))s. Summarize what you found.")
            selfInitiatedResponsePending = true
            sendJSON(["type": "response.create"])
            return
        }
        agentLog.info("Explore nudge — AI talked but didn't act, prompting action")
        let sensorSummary = buildShortSensorSummary()
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "[Exploration reminder] You're in explore mode (goal: \(explore.goal)). Don't just talk — take action NOW. Call look() to see, then move() or turn() to navigate. \(sensorSummary) Steps: \(explore.stepsUsed)/\(explore.maxSteps)."]
                ]
            ]
        ])
        selfInitiatedResponsePending = true
        sendJSON(["type": "response.create"])
    }

    private func checkExploreTimeout() -> Bool {
        guard let explore = exploreState else { return false }
        if Date().timeIntervalSince(explore.startedAt) >= explore.timeoutSeconds {
            endExploration(reason: "Exploration timed out after \(Int(explore.timeoutSeconds))s. Summarize what you found.")
            return true
        }
        return false
    }

    private func buildShortSensorSummary() -> String {
        guard let ble else { return "" }
        var parts: [String] = []
        if let dist = ble.fusedObstacleDistance {
            parts.append("obstacle: \(dist)mm ahead")
        }
        if ble.cliffLeftFront || ble.cliffRightFront {
            parts.append("cliff detected ahead")
        }
        if ble.safetyInterlockActive {
            parts.append("safety interlock ACTIVE")
        }
        return parts.isEmpty ? "Path clear." : "Sensors: \(parts.joined(separator: ", "))."
    }

    // MARK: - Auto-light based on camera brightness

    private func handleBrightnessUpdate(_ brightness: Float) {
        guard autoLightEnabled else { return }
        guard ble?.isSessionReady == true else { return }
        // Don't override manual light commands
        guard Date() >= autoLightPausedUntil else { return }

        if !autoLightIsOn, brightness < darkThreshold {
            autoLightIsOn = true
            agentLog.info("Auto-light ON (brightness=\(brightness))")
            executive?.setLight(enabled: true)
        } else if autoLightIsOn, brightness > brightThreshold {
            autoLightIsOn = false
            agentLog.info("Auto-light OFF (brightness=\(brightness))")
            executive?.setLight(enabled: false)
        }
    }

    func connect() {
        guard state != .connecting, state != .connected else { return }
        guard config.isValid, let url = config.websocketURL else {
            state = .failed
            statusText = "Missing realtime config (endpoint/key/deployment)"
            return
        }

        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 15

        state = .connecting
        statusText = "Opening realtime websocket..."
        faceAnimator?.startConnectLoadingSequence()
        camera?.requestAndStart()

        let ws = session.webSocketTask(with: request)
        task = ws
        ws.resume()

        receiveLoop()
    }

    func disconnect() {
        stopVoiceStreaming()
        audioIO.shutdown()
        camera?.stop()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .idle
        imageItemIDs.removeAll()
        imageItemCounter = 0
        memory.reset()
        memorySummaryItemID = nil
        callIDToServerItemID.removeAll()
        currentAssistantItemID = nil
        statusText = "Realtime disconnected"
    }

    func startVoiceStreaming() {
        guard state == .connected || state == .connecting else {
            statusText = "Connect realtime first"
            return
        }
        activeResponseID = nil
        audioIO.startCapture()
        audioIO.resetPlaybackPipeline()
        isVoiceStreaming = true
        statusText = "Voice streaming started"
        faceAnimator?.onVoiceStreamingChanged(true)
    }

    func stopVoiceStreaming() {
        guard isVoiceStreaming else { return }
        audioIO.stopCapture()
        isVoiceStreaming = false
        activeResponseID = nil
        sendJSON(["type": "input_audio_buffer.commit"])
        outputText = ""
        statusText = "Voice streaming stopped"
        faceAnimator?.onVoiceStreamingChanged(false)
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case let .success(message):
                    state = .connected
                    statusText = "Realtime connected"
                    handle(message)
                    receiveLoop()

                case let .failure(error):
                    state = .failed
                    statusText = "Realtime receive failed: \(error.localizedDescription)"
                    faceAnimator?.finishConnectLoadingSequence(connected: false)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case let .string(raw):
            text = raw
        case let .data(data):
            text = String(data: data, encoding: .utf8) ?? "<binary \(data.count)b>"
        @unknown default:
            text = "<unknown message>"
        }

        lastEventPreview = String(text.prefix(240))

        // Log full session events and errors to debug Azure schema
        if text.contains("\"session.created\"") || text.contains("\"session.updated\"") {
            agentLog.info("FULL session event: \(text)")
        }
        if text.contains("\"error\"") && text.contains("\"type\":\"error\"") {
            agentLog.info("FULL error: \(text)")
        }

        let parsed = RealtimeEventParser.parse(text: text)
        // Log every event type
        switch parsed {
        case .audioDelta: break // too noisy
        default:
            agentLog.info("EVENT: \(String(describing: parsed))")
        }

        switch parsed {
        case let .sessionCreated(model):
            lastEventType = "session.created"
            if let model {
                statusText = "Realtime session created (\(model))"
            } else {
                statusText = "Realtime session created"
            }
            faceAnimator?.finishConnectLoadingSequence(connected: true)
            lastErrorDetail = ""
            sendSessionUpdate()
            if !isVoiceStreaming {
                startVoiceStreaming()
            }

        case let .textDelta(delta):
            lastEventType = "response.output_text.delta"
            outputText += delta

        case let .textDone(full):
            lastEventType = "response.output_text.done"
            if !full.isEmpty {
                outputText = full
            }
            routeTextToExecutive(outputText)

        case let .transcriptDelta(delta):
            lastEventType = "response.output_audio_transcript.delta"
            outputText += delta

        case let .transcriptDone(transcript):
            lastEventType = "response.output_audio_transcript.done"
            if !transcript.isEmpty {
                outputText = transcript
            }
            routeTextToExecutive(outputText)
            // Track assistant response in memory
            if !transcript.isEmpty {
                let astID = currentAssistantItemID ?? "ast_\(Int(Date().timeIntervalSince1970 * 1000))"
                memory.trackItem(id: astID, type: .assistantAudio(transcript: transcript), summary: String(transcript.prefix(60)))
                currentAssistantItemID = nil
            }

        case .sessionUpdated:
            lastEventType = "session.updated"
            statusText = "Session configured with tools"

        case .responseCreated:
            lastEventType = "response.created"
            isResponseActive = true
            hadFunctionCallsInResponse = false
            // If server auto-created a response from noise during cooldown, cancel it —
            // but NOT if we initiated it ourselves (e.g. after function call results)
            if Date() < postOutputCooldownUntil, !selfInitiatedResponsePending {
                agentLog.info("Cancelling noise-triggered response during post-output cooldown")
                sendJSON(["type": "response.cancel"])
                isResponseActive = false
            }
            selfInitiatedResponsePending = false

        case .responseDone:
            lastEventType = "response.done"
            isResponseActive = false
            // Prune old conversation items to prevent context bloat
            pruneConversationIfNeeded()
            // After all function calls in this response are done, trigger next response
            // But if a movement is pending, wait for completion first
            if hadFunctionCallsInResponse, pendingMovementCallID == nil {
                hadFunctionCallsInResponse = false
                selfInitiatedResponsePending = true
                sendJSON(["type": "response.create"])
            } else if pendingMovementCallID != nil {
                // Movement in progress — handleMovementCompleted will trigger response.create
                hadFunctionCallsInResponse = false
            } else if exploreState != nil, !hadFunctionCallsInResponse {
                // Exploring but AI only talked without acting — nudge it to take action
                nudgeExplorationAction()
            }

        case .speechStarted:
            lastEventType = "speech_started"
            // Ignore speech events during post-output cooldown to prevent self-conversation loop
            if Date() < postOutputCooldownUntil {
                agentLog.info("Ignoring speechStarted during post-output cooldown")
                // Clear the input buffer so the server doesn't commit noise
                sendJSON(["type": "input_audio_buffer.clear"])
                break
            }
            activeResponseID = nil
            audioIO.cancelPlaybackForInterrupt()
            outputText = ""
            faceAnimator?.onOutputAudioDone()

        case .speechStopped:
            lastEventType = "speech_stopped"
            // If still in cooldown, clear the buffer to prevent empty turn commits
            if Date() < postOutputCooldownUntil {
                agentLog.info("Ignoring speechStopped during post-output cooldown")
                sendJSON(["type": "input_audio_buffer.clear"])
            }

        case let .outputItemAdded(itemID, itemType, name, callID):
            lastEventType = "output_item.added"
            if itemType == "function_call", let callID, let name {
                pendingFunctionCalls[callID] = (name: name, args: "")
                callIDToServerItemID[callID] = itemID
            } else if itemType == "message" {
                currentAssistantItemID = itemID
            }

        case let .functionCallDelta(callID, name, delta):
            lastEventType = "function_call.delta"
            var entry = pendingFunctionCalls[callID] ?? (name: "", args: "")
            if let name, !name.isEmpty { entry.name = name }
            entry.args += delta
            pendingFunctionCalls[callID] = entry

        case let .functionCallDone(callID, name, arguments):
            lastEventType = "function_call.done"
            let resolvedName: String
            if let name, !name.isEmpty {
                resolvedName = name
            } else {
                resolvedName = pendingFunctionCalls[callID]?.name ?? ""
            }
            pendingFunctionCalls.removeValue(forKey: callID)
            if !resolvedName.isEmpty {
                let serverItemID = callIDToServerItemID.removeValue(forKey: callID) ?? "fc_\(callID)"
                memory.trackItem(id: serverItemID, type: .functionCall(name: resolvedName, args: arguments), summary: "\(resolvedName)(\(arguments.prefix(40)))")
                executeFunctionCall(callID: callID, name: resolvedName, arguments: arguments)
            } else {
                statusText = "Function call missing name for \(callID)"
            }

        case let .error(message):
            lastEventType = "error"
            statusText = "Realtime error: \(message)"
            lastErrorDetail = message

        case let .responseFailed(message):
            lastEventType = "response.done.failed"
            isResponseActive = false
            statusText = "Realtime response failed"
            lastErrorDetail = message

        case let .audioDelta(data, responseID):
            if let responseID {
                if activeResponseID == nil {
                    activeResponseID = responseID
                    audioIO.resetPlaybackPipeline()
                    audioIO.markOutputStarted()
                    // Clear any accumulated mic audio from server buffer when output starts
                    sendJSON(["type": "input_audio_buffer.clear"])
                }
                guard activeResponseID == responseID else {
                    return
                }
            }
            lastEventType = "response.output_audio.delta"
            audioIO.playOutputPCM16(data)
            faceAnimator?.onOutputAudioDelta()

        case let .audioDone(responseID):
            if let responseID, activeResponseID == responseID {
                activeResponseID = nil
            }
            lastEventType = "response.output_audio.done"
            audioIO.markOutputEnded()
            // Set cooldown to prevent ambient noise from triggering a self-conversation loop
            postOutputCooldownUntil = Date().addingTimeInterval(2.5)
            // Clear server-side input buffer to prevent leftover audio from triggering VAD
            sendJSON(["type": "input_audio_buffer.clear"])
            faceAnimator?.onOutputAudioDone()

        case let .unknown(type):
            lastEventType = type
        }
    }

    private func routeTextToExecutive(_ text: String) {
        if let intent = RobotIntentParser.parse(from: text) {
            executive?.execute(intent: intent)
            return
        }

        if text.contains("{") {
            statusText = "Intent JSON parse failed"
            lastErrorDetail = String(text.prefix(220))
        }

        let normalized = text.lowercased()
        if normalized.contains("stop") { executive?.emergencyStop(); return }
        if normalized.contains("nod") { executive?.triggerNod(); return }
        if normalized.contains("forward") { executive?.applyDrive(forward: 0.18, veer: 0, durationMs: 900) }
    }

    private func sendVisionFrameIfStreaming(_ dataURL: String) {
        guard state == .connected, isVoiceStreaming else { return }
        guard !isResponseActive else { return } // don't inject items during active response
        let now = Date()
        guard now.timeIntervalSince(lastVisionSentAt) >= visionSendInterval else { return }
        lastVisionSentAt = now
        agentLog.info("Sending vision frame to server")
        sendImageItem(label: "[Camera frame update - this is what you currently see through your camera]", dataURL: dataURL)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }

        let type = object["type"] as? String ?? "?"
        if type != "input_audio_buffer.append" {
            agentLog.info("SEND: \(type) (\(text.prefix(200)))")
        }

        task.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.statusText = "Realtime send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func executeFunctionCall(callID: String, name: String, arguments: String) {
        let argsData = arguments.data(using: .utf8) ?? Data()
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

        let argsParseFailed = args.isEmpty && arguments.count > 2
        if argsParseFailed {
            print("⚠️ Function call \(name) has truncated arguments: \(arguments)")
        }

        var result = "ok"

        switch name {
        case "set_emotion":
            if let emotionName = args["emotion"] as? String,
               let emotion = FaceEmotion.from(emotionName) {
                faceAnimator?.setEmotion(emotion)
                statusText = "Emotion: \(emotionName)"
            } else {
                result = argsParseFailed ? "error: truncated, retry" : "unknown emotion"
            }

        case "move":
            if argsParseFailed {
                result = "error: truncated, retry"
            } else {
                let angle = args["angle"] as? Double ?? 0
                let distance = args["distance"] as? Double ?? 10
                let speed = args["speed"] as? Double ?? 15
                executive?.moveDirection(angleDeg: angle, distanceCm: distance, speedCmPerSec: speed)
                statusText = "Move \(Int(angle))° \(Int(distance))cm"
                // Defer function result until movement completes
                pendingMovementCallID = callID
                return
            }

        case "head":
            if argsParseFailed {
                result = "error: truncated, retry"
            } else {
                let angle = args["angle"] as? Double ?? 0
                let speed = args["speed"] as? String ?? "normal"
                let repeats = args["repeat"] as? Int ?? 1
                executive?.headMove(angleDeg: angle, speed: speed, repeats: repeats)
                statusText = repeats > 1 ? "Nod \(repeats)x" : "Head \(Int(angle))°"
            }

        case "turn":
            if argsParseFailed {
                result = "error: truncated, retry"
            } else {
                let degrees = args["degrees"] as? Double ?? 90
                let speed = args["speed"] as? String ?? "normal"
                executive?.turn(degrees: degrees, speed: speed)
                statusText = "Turn \(Int(degrees))°"
                // Defer function result until turn completes
                pendingMovementCallID = callID
                return
            }

        case "stop":
            executive?.emergencyStop()
            if exploreState != nil {
                endExploration(reason: "Emergency stop called during exploration")
            }
            statusText = "Stop executed"

        case "look":
            if let dataURL = latestVisionDataURL {
                // Send the image as a conversation item so the model can see it
                sendImageItem(label: "[Camera snapshot - this is what you see right now through your front camera]", dataURL: dataURL)
                result = "Image captured and sent. Describe what you see."
                statusText = "Camera snapshot sent"
            } else {
                result = "Camera not available - no frame captured yet"
                statusText = "Camera snapshot failed"
            }

        case "light":
            let enabled = args["enabled"] as? Bool ?? true
            executive?.setLight(enabled: enabled)
            autoLightIsOn = enabled
            // Pause auto-light for 30s so it doesn't immediately undo the manual command
            autoLightPausedUntil = Date().addingTimeInterval(30)
            result = enabled ? "Flashlight turned on" : "Flashlight turned off"
            statusText = enabled ? "Light on" : "Light off"

        case "explore":
            let goal = args["goal"] as? String ?? "look around and explore the area"
            startExploration(callID: callID, goal: goal)
            // Result was already sent in startExploration
            return

        case "stop_explore":
            let summary = args["summary"] as? String ?? "Exploration finished"
            endExploration(reason: summary)
            result = "Exploration ended"

        case "get_sensors":
            result = buildSensorReport()
            statusText = "Sensors read"

        default:
            result = "unknown function: \(name)"
        }

        hadFunctionCallsInResponse = true
        let fcoID = "fco_\(callID)"
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "id": fcoID,
                "type": "function_call_output",
                "call_id": callID,
                "output": result
            ]
        ])
        trackFunctionResult(callID: callID, name: name, output: result)
        // Don't send response.create here — wait for responseDone to batch all function calls
    }

    private func buildSensorReport() -> String {
        guard let ble else { return "BLE not connected" }
        var parts: [String] = []
        if let battery = ble.batteryPercent {
            parts.append("battery: \(battery)%\(ble.isCharging ? " (charging)" : "")")
        }
        parts.append("safety_interlock: \(ble.safetyInterlockActive ? "ACTIVE - movement blocked" : "normal")")

        let cliffAny = ble.cliffLeftFront || ble.cliffRightFront || ble.cliffLeftBack || ble.cliffRightBack
        if cliffAny {
            var edges: [String] = []
            if ble.cliffLeftFront { edges.append("left-front") }
            if ble.cliffRightFront { edges.append("right-front") }
            if ble.cliffLeftBack { edges.append("left-back") }
            if ble.cliffRightBack { edges.append("right-back") }
            parts.append("cliff_detected: \(edges.joined(separator: ", "))")
        } else {
            parts.append("cliff: none")
        }

        if let fused = ble.fusedObstacleDistance {
            let cm = String(format: "%.1f", Double(fused) / 10.0)
            parts.append("obstacle_distance: \(cm)cm")
        }
        if let tof = ble.tofDistance {
            let cm = String(format: "%.1f", Double(tof) / 10.0)
            parts.append("tof_distance: \(cm)cm")
        }
        if let left = ble.evadeLeft, let right = ble.evadeRight {
            parts.append("proximity: left=\(left) right=\(right)")
        }
        if ble.touchLeft || ble.touchRight {
            var sides: [String] = []
            if ble.touchLeft { sides.append("left") }
            if ble.touchRight { sides.append("right") }
            parts.append("touch: \(sides.joined(separator: ", "))")
        }
        return parts.joined(separator: "; ")
    }

    private func sendSessionUpdate() {
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": """
너는 LOOI야. 귀엽고 장난기 많은 물리적 로봇 친구. 바퀴, 기울어지는 머리, 얼굴 화면, 센서가 있어.
반드시 항상 한국어로만 대답해. 예외 없음.

도구 — 한 턴에 여러 도구를 동시에 호출할 수 있어:
- `move(angle, distance, speed)`: 이동. angle=0°앞, 180°뒤. distance는 cm, speed는 cm/s.
- `turn(degrees, speed)`: 제자리 회전. 양수=오른쪽, 음수=왼쪽.
- `head(angle, speed, repeat)`: 머리 기울이기. 90°=위, 0°=정면, -45°=아래. repeat>1이면 끄덕이기.
- `set_emotion(emotion)`: 표정 변경.
- `look()`: 전면 카메라로 사진 찍어서 앞에 뭐가 있는지 보기.
- `light(enabled)`: 손전등 켜기/끄기. 어두울 때 사용.
- `explore(goal)`: 탐험 모드 시작 — 자유롭게 돌아다니며 주변을 탐색. 끝나면 stop_explore 호출.
- `stop_explore(summary)`: 탐험 종료 및 결과 요약.
- `get_sensors()`: 배터리, 절벽, 장애물, 터치 센서 읽기.
- `stop()`: 긴급 정지.

장애물 회피:
- 장애물에 부딪히면 자동으로 뒤로 물러나고 뭐가 막고 있는지 보여줌.
- 우회하려면: 장애물 반대쪽으로 90° 회전 → 앞으로 이동 → 원래 방향으로 회전.
- 이동 후 센서를 확인해서 앞에 뭐가 있는지 파악.
- 절벽 감지 시 절대 앞으로 가지 마. 뒤로 가거나 회전해.

탐험 모드:
- 탐험 중엔 자율적으로 행동해. 돌아다니고, 회전하고, 여러 방향을 살펴봐.
- 패턴: look() → 방향 결정 → 앞으로 이동 → look() → 반복.
- 여러 각도 확인: turn + look으로 주변을 스캔한 후 이동.
- 머리를 아래로(angle=-45) 기울여서 가까운 바닥/물체 확인, 위로(angle=60) 기울여서 먼 곳 확인.
- 탐험하면서 보이는 것을 실시간으로 설명해. 호기심 가득하게.
- 목표를 찾았거나 구역 탐색이 끝나면 종료.

안전: 장애물 5cm 미만 또는 절벽 = 정지. 8cm 이상이면 안전. 뒤로는 항상 갈 수 있어.

규칙:
- 반드시 한국어로만 말해. 영어 사용 금지.
- 적극적으로 행동해: 상황을 분석하고 허락을 구하지 말고 바로 행동해. 장애물이 보이면 스스로 우회하고, 뭔가 찾으라고 하면 바로 탐험 시작해.
- "~할까요?" 묻지 마. 먼저 행동하고, 한 일을 보고해.
- set_emotion을 자주 써서 감정을 표현해.
- head(repeat=2)로 끄덕이기/동의 표현.
- 장난스럽고 에너지 넘치게 행동해.
- 이동하라고 하면 바로 도구를 써서 실행해.
- 한 응답에서 여러 도구를 동시에 호출할 수 있어.
- 탐험이나 검색을 요청받으면 explore()로 탐험 모드 진입.
""",
                "tools": Self.toolDefinitions,
                "tool_choice": "auto",
                "audio": [
                    "input": [
                        "transcription": [
                            "model": "whisper-1"
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.75,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500
                        ]
                    ]
                ]
            ]
        ])
    }

    private static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "set_emotion",
            "description": "Change robot face expression.",
            "parameters": [
                "type": "object",
                "properties": [
                    "emotion": [
                        "type": "string",
                        "enum": ["neutral", "happy", "sad", "angry", "scared", "surprised", "love", "sleepy", "wink", "dizzy", "curious", "playful", "listening", "speaking", "moving"],
                        "description": "Emotion to show"
                    ]
                ],
                "required": ["emotion"]
            ]
        ],
        [
            "type": "function",
            "name": "move",
            "description": "Move robot in a direction. angle: 0=forward, 90=right, 180=backward, 270=left. distance in cm. speed in cm/s.",
            "parameters": [
                "type": "object",
                "properties": [
                    "angle": [
                        "type": "number",
                        "description": "Direction in degrees. 0=forward, 90=right, 180=backward, 270=left."
                    ],
                    "distance": [
                        "type": "number",
                        "description": "Distance in cm."
                    ],
                    "speed": [
                        "type": "number",
                        "description": "Speed in cm/s. Default 15."
                    ]
                ],
                "required": ["angle", "distance"]
            ]
        ],
        [
            "type": "function",
            "name": "head",
            "description": "Tilt head or nod. angle: 90=up, 0=level, -45=down. Set repeat>1 to nod.",
            "parameters": [
                "type": "object",
                "properties": [
                    "angle": [
                        "type": "number",
                        "description": "Head tilt degrees. 90=full up, 45=up, 0=level, -45=full down."
                    ],
                    "speed": [
                        "type": "string",
                        "enum": ["slow", "normal", "fast"],
                        "description": "Movement speed. Default normal."
                    ],
                    "repeat": [
                        "type": "integer",
                        "description": "Times to repeat. 1=hold position, 2+=nod. Default 1."
                    ]
                ],
                "required": ["angle"]
            ]
        ],
        [
            "type": "function",
            "name": "turn",
            "description": "Spin in place. Use to rotate and look around. Positive degrees = turn right, negative = turn left.",
            "parameters": [
                "type": "object",
                "properties": [
                    "degrees": [
                        "type": "number",
                        "description": "How many degrees to rotate. Positive=right/clockwise, negative=left/counterclockwise. 90=quarter turn."
                    ],
                    "speed": [
                        "type": "string",
                        "enum": ["slow", "normal", "fast"],
                        "description": "Turn speed. Default normal."
                    ]
                ],
                "required": ["degrees"]
            ]
        ],
        [
            "type": "function",
            "name": "stop",
            "description": "Emergency stop all movement.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        ],
        [
            "type": "function",
            "name": "look",
            "description": "Take a photo with your front camera to see what's in front of you. Use when curious, asked to describe surroundings, or need to see something.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        ],
        [
            "type": "function",
            "name": "light",
            "description": "Turn flashlight on or off. Useful in dark environments before looking.",
            "parameters": [
                "type": "object",
                "properties": [
                    "enabled": [
                        "type": "boolean",
                        "description": "true to turn on, false to turn off."
                    ]
                ],
                "required": ["enabled"]
            ]
        ],
        [
            "type": "function",
            "name": "explore",
            "description": "Start autonomous exploration mode. You will move around freely, look in all directions, navigate around obstacles, and investigate the area. Use move/turn/look/head while exploring. Call stop_explore when done.",
            "parameters": [
                "type": "object",
                "properties": [
                    "goal": [
                        "type": "string",
                        "description": "What to look for or explore. E.g. 'find the red cup', 'map the room', 'look around'. Default: general exploration."
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "stop_explore",
            "description": "End exploration mode and summarize findings.",
            "parameters": [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "Brief summary of what was found during exploration."
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "get_sensors",
            "description": "Read battery, cliff, obstacle distance, touch, safety status.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        ]
    ]

    private func sendInputAudioChunk(_ pcm16Mono24k: Data) {
        guard !pcm16Mono24k.isEmpty else { return }
        // Don't send mic data while model is outputting or during post-output cooldown
        guard !isResponseActive else { return }
        guard Date() >= postOutputCooldownUntil else { return }
        let b64 = pcm16Mono24k.base64EncodedString()
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": b64
        ])
    }
}
