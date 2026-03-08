import Combine
import Foundation

@MainActor
final class FaceAnimator: ObservableObject {
    @Published var emotion: FaceEmotion = .sleeping
    @Published var currentLooiCode: String? = LooiFaceCodeMap.code(for: .sleeping)
    @Published var isLoadingSequence = false
    /// Local file path for the current PAG animation (nil if not yet cached)
    @Published var currentPAGPath: String?

    private var loadingTask: Task<Void, Never>?
    private var pagLoadTask: Task<Void, Never>?
    private var revertTask: Task<Void, Never>?

    /// When an explicit emotion is set (via AI), auto-state changes (audio) are blocked until this date
    private var emotionLockedUntil: Date = .distantPast

    /// Whether the current emotion was explicitly requested (not from audio/move events)
    private var isExplicitEmotion = false

    init() {
        let codes = LooiFaceCodeMap.primaryCodeByEmotion.values.map { $0 }
        PAGFileCache.shared.preload(codes: codes)
        loadPAGForCurrentEmotion()
    }

    func startConnectLoadingSequence() {
        loadingTask?.cancel()
        revertTask?.cancel()
        isLoadingSequence = true
        isExplicitEmotion = false
        emotionLockedUntil = .distantPast
        applyEmotion(.sleeping)

        loadingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            applyEmotion(.waking)

            try? await Task.sleep(nanoseconds: 850_000_000)
            if Task.isCancelled { return }
            applyEmotion(.neutral)
            isLoadingSequence = false
        }
    }

    func finishConnectLoadingSequence(connected: Bool) {
        loadingTask?.cancel()
        loadingTask = nil
        isLoadingSequence = false
        isExplicitEmotion = false
        applyEmotion(connected ? .neutral : .sleeping)
    }

    func onVoiceStreamingChanged(_ isStreaming: Bool) {
        guard !isLoadingSequence else { return }
        guard !isEmotionLocked else { return }
        applyEmotion(isStreaming ? .listening : .neutral)
    }

    func onOutputAudioDelta() {
        guard !isLoadingSequence else { return }
        // During explicit emotion lock, only switch to speaking if the locked emotion
        // is a "conversation" type (listening/neutral). Don't override sleeping, happy, etc.
        if isEmotionLocked {
            let conversationEmotions: Set<FaceEmotion> = [.listening, .neutral, .speaking]
            guard conversationEmotions.contains(emotion) else { return }
        }
        applyEmotion(.speaking)
    }

    func onOutputAudioDone() {
        guard !isLoadingSequence else { return }
        guard !isEmotionLocked else { return }
        applyEmotion(.neutral)
    }

    func onMoveTriggered() {
        guard !isLoadingSequence else { return }
        guard !isEmotionLocked else { return }
        applyEmotion(.moving)
        scheduleRevert(from: .moving, after: 1.5)
    }

    func onSafetyStopTriggered() {
        guard !isLoadingSequence else { return }
        // Safety stop always overrides
        isExplicitEmotion = false
        emotionLockedUntil = .distantPast
        applyEmotion(.scared)
        scheduleRevert(from: .scared, after: 2.0)
    }

    /// Explicit emotion request from AI agent. Locks out auto-state changes.
    func setEmotion(_ emotion: FaceEmotion) {
        guard !isLoadingSequence else { return }
        revertTask?.cancel()
        isExplicitEmotion = true
        applyEmotion(emotion)

        // Persistent emotions: don't auto-revert
        let persistentEmotions: Set<FaceEmotion> = [.sleeping, .waking, .listening, .speaking, .moving]
        if persistentEmotions.contains(emotion) {
            // Lock for a moderate duration so audio events don't immediately override
            emotionLockedUntil = Date().addingTimeInterval(5.0)
            return
        }

        // Transient emotions: show for 5 seconds, then revert
        emotionLockedUntil = Date().addingTimeInterval(5.0)
        scheduleRevert(from: emotion, after: 5.0)
    }

    // MARK: - Private

    private var isEmotionLocked: Bool {
        Date() < emotionLockedUntil
    }

    private func scheduleRevert(from targetEmotion: FaceEmotion, after seconds: TimeInterval) {
        revertTask?.cancel()
        revertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isLoadingSequence else { return }
                if self.emotion == targetEmotion {
                    self.isExplicitEmotion = false
                    self.emotionLockedUntil = .distantPast
                    self.applyEmotion(.neutral)
                }
            }
        }
    }

    private func applyEmotion(_ newEmotion: FaceEmotion) {
        emotion = newEmotion
        currentLooiCode = LooiFaceCodeMap.code(for: newEmotion)
        loadPAGForCurrentEmotion()
    }

    private func loadPAGForCurrentEmotion() {
        guard let code = currentLooiCode else {
            currentPAGPath = nil
            return
        }

        if let cached = PAGFileCache.shared.cachedFileURL(for: code) {
            currentPAGPath = cached.path
            return
        }

        pagLoadTask?.cancel()
        pagLoadTask = Task { [weak self, code] in
            let url = await PAGFileCache.shared.fileURL(for: code)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.currentLooiCode == code else { return }
                self.currentPAGPath = url?.path
            }
        }
    }
}
