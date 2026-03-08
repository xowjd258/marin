import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @StateObject private var agent = RealtimeAgentClient()
    @StateObject private var camera = CameraCaptureManager()
    @StateObject private var executive = RobotExecutive()
    @StateObject private var faceAnimator = FaceAnimator()
#if os(iOS)
    @StateObject private var faceTracker = FaceTracker()
#endif

    var body: some View {
        RobotFaceView(
            emotion: faceAnimator.emotion,
            isAnimated: true,
            looiCode: faceAnimator.currentLooiCode,
            pagFilePath: faceAnimator.currentPAGPath
        )
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onAppear {
            executive.bind(ble: ble)
            agent.bind(executive: executive)
            agent.bind(faceAnimator: faceAnimator)
            agent.bind(camera: camera)
            agent.bind(ble: ble)

            executive.onMotionTriggered = {
                faceAnimator.onMoveTriggered()
            }
            executive.onSafetyStopTriggered = {
                faceAnimator.onSafetyStopTriggered()
            }
            executive.onEmotionRequested = { emotion in
                faceAnimator.setEmotion(emotion)
            }

            camera.onSampledFrameDataURL = { dataURL in
                Task { @MainActor in
                    agent.updateVisionFrameDataURL(dataURL)
                }
            }

            ble.onSafetyInterlockTriggered = { reason in
                agent.notifySensorEvent(reason: reason)
            }

#if os(iOS)
            camera.onSampleBuffer = { [faceTracker] sampleBuffer in
                faceTracker.processSampleBuffer(sampleBuffer)
            }
            faceTracker.onTrackingUpdate = { [weak executive] headAngle, turnVeer in
                executive?.setHeadAngle(headAngle)
                if abs(turnVeer) > 0.05 {
                    executive?.applyDrive(forward: 0, veer: turnVeer, durationMs: 150)
                }
            }
#endif

            // Auto-connect on launch
            agent.connect()
        }
#if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            camera.resumeIfNeeded()
        }
#endif
    }
}

#Preview {
    ContentView()
}
