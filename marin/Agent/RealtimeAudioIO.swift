import AVFoundation
import Combine
import Foundation
import os

private let audioLog = Logger(subsystem: "marin", category: "AudioIO")

final class RealtimeAudioIO: ObservableObject {
    @MainActor @Published var isCapturing = false
    @MainActor @Published var statusText = "Audio idle"
    @MainActor @Published var receivedOutputBytes: Int = 0

    var onInputPCM16Chunk: ((Data) -> Void)?
    var onLoudInputDetectedDuringPlayback: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let processingQueue = DispatchQueue(label: "realtime.audio.io.queue")
    private let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    private var graphConfigured = false
    private var inputTapInstalled = false
    private var queuedOutputPCM = Data()
    private var playbackScheduled = false
    private var isPlaybackEnabled = true

    /// true while the player is actively outputting audio
    private var isOutputtingAudio = false
    /// timestamp when output playback last finished
    private var outputEndedAt: Date = .distantPast
    /// how long after playback ends to keep the mic gated (echo tail)
    private let echoTailGuardSeconds: TimeInterval = 0.35
    /// true when server has signaled audio is done but buffers may still be playing
    private var serverAudioDone = false
    /// RMS threshold to detect a real user voice over echo residue
    private let interruptRMSThreshold: Float = 0.08

    func startCapture() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureAudioSessionIfNeeded()
                try self.configureEngineIfNeeded()
                self.installInputTapIfNeeded()
                if !self.audioEngine.isRunning {
                    try self.audioEngine.start()
                }
                if !self.playerNode.isPlaying {
                    self.playerNode.play()
                }
                Task { @MainActor [weak self] in
                    self?.isCapturing = true
                    self?.statusText = "Audio capturing"
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isCapturing = false
                    self?.statusText = "Audio start failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopCapture() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.inputTapInstalled {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.inputTapInstalled = false
            }
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                self?.statusText = "Audio stopped"
            }
        }
    }

    func shutdown() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.inputTapInstalled {
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
            self.inputTapInstalled = false
            self.playerNode.stop()
            self.audioEngine.stop()
            self.queuedOutputPCM.removeAll(keepingCapacity: false)
            self.playbackScheduled = false
            self.isPlaybackEnabled = false
            self.isOutputtingAudio = false
            self.serverAudioDone = false
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                self?.statusText = "Audio idle"
            }
        }
    }

    func markOutputStarted() {
        processingQueue.async { [weak self] in
            audioLog.info(">>> OUTPUT STARTED (mic muted)")
            self?.isOutputtingAudio = true
        }
    }

    func markOutputEnded() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            // Don't unmute mic yet — buffered audio may still be playing.
            // Set flag so that when the last buffer finishes, we start the tail guard then.
            self.serverAudioDone = true
            // If nothing is currently scheduled (all buffers already played), unmute now
            if !self.playbackScheduled, self.queuedOutputPCM.isEmpty {
                audioLog.info(">>> OUTPUT ENDED (no pending buffers, mic unmute after tail guard)")
                self.isOutputtingAudio = false
                self.outputEndedAt = Date()
                self.serverAudioDone = false
            } else {
                audioLog.info(">>> OUTPUT ENDED (server done, waiting for playback buffers)")
            }
        }
    }

    func cancelPlaybackForInterrupt() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedOutputPCM.removeAll(keepingCapacity: false)
            self.playbackScheduled = false
            self.isOutputtingAudio = false
            self.serverAudioDone = false
            self.outputEndedAt = .distantPast
            if self.graphConfigured, !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }

    func resetPlaybackPipeline() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedOutputPCM.removeAll(keepingCapacity: false)
            self.playbackScheduled = false
            self.isPlaybackEnabled = true
            self.isOutputtingAudio = false
            self.serverAudioDone = false
            if self.graphConfigured, !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }

    func playOutputPCM16(_ data: Data, sampleRate: Double = 24_000) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            guard !data.isEmpty else { return }
            guard self.isPlaybackEnabled else { return }
            self.queuedOutputPCM.append(data)
            Task { @MainActor [weak self] in
                self?.receivedOutputBytes += data.count
            }
            self.schedulePlaybackIfNeeded(sampleRate: sampleRate)
        }
    }

    private func schedulePlaybackIfNeeded(sampleRate: Double) {
        guard isPlaybackEnabled else { return }
        guard graphConfigured else { return }
        guard !playbackScheduled else { return }
        guard queuedOutputPCM.count >= 2048 else { return }

        playbackScheduled = true
        let chunk = queuedOutputPCM
        queuedOutputPCM.removeAll(keepingCapacity: true)

        guard let format = playerFormat else {
            playbackScheduled = false
            return
        }

        let frameCount = UInt32(chunk.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            playbackScheduled = false
            return
        }
        buffer.frameLength = frameCount

        chunk.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.bindMemory(to: Int16.self).baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            let channels = Int(format.channelCount)
            for i in 0 ..< Int(frameCount) {
                let normalized = Float(src[i]) / Float(Int16.max)
                for ch in 0 ..< channels {
                    channelData[ch][i] = normalized
                }
            }
        }

        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.processingQueue.async {
                self.playbackScheduled = false
                // If server signaled audio done and no more data to play, start tail guard now
                if self.serverAudioDone, self.queuedOutputPCM.isEmpty {
                    audioLog.info(">>> PLAYBACK BUFFER DONE (mic unmute after tail guard)")
                    self.isOutputtingAudio = false
                    self.outputEndedAt = Date()
                    self.serverAudioDone = false
                } else {
                    self.schedulePlaybackIfNeeded(sampleRate: sampleRate)
                }
            }
        }
    }

    private func configureAudioSessionIfNeeded() throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(24_000)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif
    }

    private func configureEngineIfNeeded() throws {
        guard !graphConfigured else { return }
        guard let playerFormat else { return }

        audioEngine.attach(playerNode)
        let mixer = audioEngine.mainMixerNode
        _ = audioEngine.inputNode

        audioEngine.connect(playerNode, to: mixer, format: playerFormat)

        graphConfigured = true
    }

    private func installInputTapIfNeeded() {
        guard !inputTapInstalled else { return }
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        audioLog.debug("installInputTap format=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.computeRMS(buffer: buffer)

            if self.isOutputtingAudio {
                if rms > self.interruptRMSThreshold {
                    audioLog.info("LOUD during playback rms=\(rms) -> interrupt")
                    self.onLoudInputDetectedDuringPlayback?()
                }
                return
            }

            let tailElapsed = Date().timeIntervalSince(self.outputEndedAt)
            if tailElapsed < self.echoTailGuardSeconds {
                return
            }

            // Log every ~50th chunk to avoid spam (1024 samples at 48kHz ≈ 21ms, so ~50 = 1 per second)
            if Int.random(in: 0..<50) == 0 {
                audioLog.debug("mic->server rms=\(rms)")
            }

            let chunk = Self.convertToPCM16Mono24k(buffer: buffer)
            guard !chunk.isEmpty else { return }

            // Gate: replace near-silence with zero audio to prevent noise-triggered VAD
            // but keep sending data so the server connection stays alive
            if rms < 0.005 {
                self.onInputPCM16Chunk?(Data(count: chunk.count))
                return
            }
            self.onInputPCM16Chunk?(chunk)
        }
        inputTapInstalled = true
    }

    private static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0 ..< frames {
            let s = floatData[0][i]
            sum += s * s
        }
        return sqrtf(sum / Float(frames))
    }

    private static func convertToPCM16Mono24k(buffer: AVAudioPCMBuffer) -> Data {
        guard let floatData = buffer.floatChannelData else { return Data() }
        let inFrames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard inFrames > 0, channels > 0 else { return Data() }

        let inRate = buffer.format.sampleRate
        let outRate = 24_000.0
        let ratio = inRate / outRate
        if ratio <= 0 { return Data() }

        let outFrames = max(1, Int(Double(inFrames) / ratio))
        var out = Data(capacity: outFrames * 2)

        for i in 0 ..< outFrames {
            let srcIndex = min(inFrames - 1, Int(Double(i) * ratio))
            var mixed: Float = 0
            for ch in 0 ..< channels {
                mixed += floatData[ch][srcIndex]
            }
            mixed /= Float(channels)
            let clamped = max(-1.0, min(1.0, mixed))
            var s = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
        }

        return out
    }
}
