import AVFoundation
import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

final class CameraCaptureManager: NSObject, ObservableObject {
    enum PermissionState: String {
        case unknown = "Unknown"
        case denied = "Denied"
        case granted = "Granted"
    }

    @MainActor @Published var permission: PermissionState = .unknown
    @MainActor @Published var isRunning = false
    @MainActor @Published var statusText = "Camera idle"
    @MainActor @Published var hasRecentFrame = false

    var onSampledFrameDataURL: ((String) -> Void)?
    /// Called with average frame brightness (0.0=black, 1.0=white) on every sampled frame
    var onBrightnessUpdated: ((Float) -> Void)?
    /// Called with every camera sample buffer for face detection (on video output queue)
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameCounter = 0

    override init() {
        super.init()
        Task { @MainActor in
            refreshPermissionState()
        }
    }

    @MainActor
    func refreshPermissionState() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .denied, .restricted:
            permission = .denied
        case .notDetermined:
            permission = .unknown
        @unknown default:
            permission = .unknown
        }
    }

    @MainActor
    func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
            startSessionIfNeeded()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    permission = granted ? .granted : .denied
                    if granted {
                        startSessionIfNeeded()
                    } else {
                        statusText = "Camera permission denied"
                    }
                }
            }

        case .denied, .restricted:
            permission = .denied
            statusText = "Camera permission denied"

        @unknown default:
            permission = .denied
            statusText = "Camera unavailable"
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false  // Set immediately to avoid race conditions
        statusText = "Camera stopped"
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    @MainActor
    private func startSessionIfNeeded() {
        guard !isRunning else { return }
        statusText = "Starting camera..."
        isRunning = true  // Set immediately to avoid race conditions

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            self.session.startRunning()
            Task { @MainActor [weak self] in
                self?.statusText = "Camera running"
            }
        }
    }

    /// Resume capture session after returning from background
    @MainActor
    func resumeIfNeeded() {
        guard permission == .granted, !isRunning else { return }
        startSessionIfNeeded()
    }

    private func configureSessionIfNeeded() {
        if !session.inputs.isEmpty { return }
        session.beginConfiguration()
        session.sessionPreset = .medium

        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }

        session.addInput(input)

        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            session.addOutput(videoOutput)
        }
    }
}

extension CameraCaptureManager {
    /// Compute average luminance (0.0–1.0) from a BGRA pixel buffer by sampling every 16th pixel
    static func averageBrightness(of pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var sum: Int = 0
        var count: Int = 0
        let step = 16  // sample every 16th pixel for speed

        for y in stride(from: 0, to: height, by: step) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let pixelOffset = rowOffset + x * 4  // BGRA = 4 bytes
                let b = Int(ptr[pixelOffset])
                let g = Int(ptr[pixelOffset + 1])
                let r = Int(ptr[pixelOffset + 2])
                // ITU-R BT.601 luminance
                sum += (r * 77 + g * 150 + b * 29) >> 8
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        return Float(sum) / Float(count) / 255.0
    }
}

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Face detection runs on every frame (FaceTracker internally rate-limits)
        onSampleBuffer?(sampleBuffer)

        frameCounter += 1
        if frameCounter % 12 != 0 { return }

#if os(iOS)
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Compute average brightness from pixel buffer
        let brightness = Self.averageBrightness(of: imageBuffer)

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.35) else { return }
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"

        Task { @MainActor [weak self] in
            self?.hasRecentFrame = true
            self?.onSampledFrameDataURL?(dataURL)
            self?.onBrightnessUpdated?(brightness)
        }
#endif
    }
}
