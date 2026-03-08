#if os(iOS)
import libpag
import SwiftUI
import os

private let pagLog = Logger(subsystem: "marin", category: "PAGFaceView")

/// SwiftUI wrapper for PAGView that displays LOOI face animations.
struct PAGFaceView: UIViewRepresentable {
    let pagFilePath: String?
    let isPlaying: Bool

    func makeUIView(context: Context) -> PAGView {
        let view = PAGView()
        view.setRepeatCount(0) // infinite loop
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PAGView, context: Context) {
        if let path = pagFilePath, path != context.coordinator.currentPath {
            context.coordinator.currentPath = path
            uiView.setPath(path)
            if isPlaying {
                uiView.play()
            }
        }

        if isPlaying, !uiView.isPlaying() {
            uiView.play()
        } else if !isPlaying, uiView.isPlaying() {
            uiView.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var currentPath: String?
    }
}
#endif
