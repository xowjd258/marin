#if os(iOS)
import AVFoundation
import Combine
import Foundation
import Vision
import os

private let faceLog = Logger(subsystem: "marin", category: "FaceTracker")

/// Detects faces in camera frames and produces tracking signals for robot head/body movement.
/// Runs entirely on-device using Vision framework — no AI agent needed.
@MainActor
final class FaceTracker: ObservableObject {
    @Published var isTracking = false
    @Published var faceDetected = false
    /// Normalized face center X (-1.0=left, 0=center, 1.0=right)
    @Published var faceCenterX: Double = 0
    /// Normalized face center Y (-1.0=bottom, 0=center, 1.0=top)
    @Published var faceCenterY: Double = 0

    /// Called with (headAngle, turnVeer) whenever face position should adjust robot
    var onTrackingUpdate: ((Double, Double) -> Void)?

    private var isEnabled = true
    private let detectionQueue = DispatchQueue(label: "face.detection.queue", qos: .userInitiated)

    // Thread-safe rate limiting (accessed from video output queue)
    private let _lastDetectionTime = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let _isDetecting = OSAllocatedUnfairLock(initialState: false)
    private let detectionInterval: TimeInterval = 0.3

    // Smoothing (MainActor only)
    private var smoothedX: Double = 0
    private var smoothedY: Double = 0
    private let smoothingAlpha: Double = 0.3

    // Dead zone
    private let deadZoneX: Double = 0.12
    private let deadZoneY: Double = 0.10

    // Face lost timeout
    private var lastFaceSeenAt: Date = .distantPast
    private let faceLostTimeout: TimeInterval = 1.0

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            faceDetected = false
            smoothedX = 0
            smoothedY = 0
        }
    }

    /// Process a camera sample buffer for face detection.
    /// Call from CameraCaptureManager's delegate (on video output queue).
    nonisolated func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()

        // Rate limit (thread-safe)
        let shouldSkip = _lastDetectionTime.withLock { lastTime in
            now.timeIntervalSince(lastTime) < detectionInterval
        }
        if shouldSkip { return }

        let alreadyDetecting = _isDetecting.withLock { detecting in
            if detecting { return true }
            detecting = true
            return false
        }
        if alreadyDetecting { return }

        _lastDetectionTime.withLock { $0 = now }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            _isDetecting.withLock { $0 = false }
            return
        }

        let request = VNDetectFaceRectanglesRequest { [weak self] request, error in
            guard let self else { return }
            self._isDetecting.withLock { $0 = false }

            if let error {
                faceLog.error("Face detection error: \(error.localizedDescription)")
                return
            }

            let faces = (request.results as? [VNFaceObservation]) ?? []
            Task { @MainActor [weak self] in
                self?.handleDetectionResults(faces)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        detectionQueue.async {
            try? handler.perform([request])
        }
    }

    private func handleDetectionResults(_ faces: [VNFaceObservation]) {
        guard isEnabled else { return }

        // Pick the largest face
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            if Date().timeIntervalSince(lastFaceSeenAt) > faceLostTimeout {
                faceDetected = false
            }
            return
        }

        lastFaceSeenAt = Date()
        faceDetected = true

        // Vision coords: origin bottom-left, (0,0)-(1,1)
        let rawX = Double(face.boundingBox.midX)
        let rawY = Double(face.boundingBox.midY)

        // Convert to centered coords (-1 to 1)
        let centeredX = (rawX - 0.5) * 2.0
        let centeredY = (rawY - 0.5) * 2.0

        // Smooth
        smoothedX = smoothedX + (centeredX - smoothedX) * smoothingAlpha
        smoothedY = smoothedY + (centeredY - smoothedY) * smoothingAlpha

        faceCenterX = smoothedX
        faceCenterY = smoothedY

        // Apply dead zone
        let adjustX = abs(smoothedX) > deadZoneX ? smoothedX : 0
        let adjustY = abs(smoothedY) > deadZoneY ? smoothedY : 0

        guard adjustX != 0 || adjustY != 0 else { return }

        // Head angle: 0.5=level, higher=up. Face higher in frame → head tilts up.
        let headAdjust = adjustY * 0.15
        let headAngle = 0.5 + headAdjust

        // Turn: face to the right → robot turns right (negative veer for LOOI)
        let turnVeer = -adjustX * 0.12

        onTrackingUpdate?(headAngle, turnVeer)
    }
}
#endif
