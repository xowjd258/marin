import SwiftUI

struct RobotFaceView: View {
    let emotion: FaceEmotion
    let isAnimated: Bool
    let looiCode: String?
    let pagFilePath: String?

    init(emotion: FaceEmotion, isAnimated: Bool, looiCode: String?, pagFilePath: String? = nil) {
        self.emotion = emotion
        self.isAnimated = isAnimated
        self.looiCode = looiCode
        self.pagFilePath = pagFilePath
    }

    @State private var pulse = false

    var body: some View {
#if os(iOS)
        if pagFilePath != nil {
            PAGFaceView(pagFilePath: pagFilePath, isPlaying: isAnimated)
        } else {
            fallbackFace
        }
#else
        fallbackFace
#endif
    }

    private var fallbackFace: some View {
        ZStack {
            Rectangle()
                .fill(backgroundGradient)

            HStack(spacing: 30) {
                eyeView
                eyeView
            }
            .scaleEffect(x: 1, y: verticalScaleForEmotion)
            .opacity(opacityForEmotion)

            if emotion == .sleeping {
                Text("z z")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .offset(x: 66, y: -28)
            }

            if emotion == .love {
                Text("♡")
                    .font(.title3)
                    .foregroundStyle(.pink.opacity(0.9))
                    .offset(x: 62, y: -26)
            }

            if emotion == .dizzy {
                Text("@")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: -62, y: -26)
            }
        }
        .scaleEffect(isAnimated && pulse ? 1.01 : 1.0)
        .onAppear {
            guard isAnimated else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var eyeView: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.92))
            .frame(width: 28, height: eyeHeight)
    }

    private var backgroundGradient: LinearGradient {
        switch emotion {
        case .sleeping:
            return LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.18), Color(red: 0.09, green: 0.15, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .waking:
            return LinearGradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.33), Color(red: 0.18, green: 0.31, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .speaking:
            return LinearGradient(colors: [Color(red: 0.14, green: 0.30, blue: 0.49), Color(red: 0.20, green: 0.42, blue: 0.63)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .moving:
            return LinearGradient(colors: [Color(red: 0.20, green: 0.29, blue: 0.44), Color(red: 0.22, green: 0.40, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .scared:
            return LinearGradient(colors: [Color(red: 0.30, green: 0.16, blue: 0.14), Color(red: 0.36, green: 0.20, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .surprised:
            return LinearGradient(colors: [Color(red: 0.21, green: 0.24, blue: 0.46), Color(red: 0.28, green: 0.36, blue: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sad:
            return LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.27), Color(red: 0.12, green: 0.20, blue: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .angry:
            return LinearGradient(colors: [Color(red: 0.33, green: 0.16, blue: 0.14), Color(red: 0.47, green: 0.18, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .love:
            return LinearGradient(colors: [Color(red: 0.32, green: 0.18, blue: 0.34), Color(red: 0.45, green: 0.22, blue: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .wink:
            return LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.44), Color(red: 0.22, green: 0.42, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dizzy:
            return LinearGradient(colors: [Color(red: 0.24, green: 0.22, blue: 0.25), Color(red: 0.31, green: 0.29, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .curious:
            return LinearGradient(colors: [Color(red: 0.12, green: 0.29, blue: 0.35), Color(red: 0.18, green: 0.40, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .playful:
            return LinearGradient(colors: [Color(red: 0.14, green: 0.31, blue: 0.32), Color(red: 0.24, green: 0.46, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .happy:
            return LinearGradient(colors: [Color(red: 0.15, green: 0.32, blue: 0.50), Color(red: 0.24, green: 0.48, blue: 0.66)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .listening, .neutral:
            return LinearGradient(colors: [Color(red: 0.11, green: 0.24, blue: 0.40), Color(red: 0.18, green: 0.34, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var eyeHeight: CGFloat {
        switch emotion {
        case .sleeping: return 3
        case .waking: return 10
        case .listening: return 20
        case .speaking: return 16
        case .moving: return 18
        case .scared: return 22
        case .surprised: return 24
        case .sad: return 10
        case .angry: return 12
        case .love: return 14
        case .wink: return 9
        case .dizzy: return 19
        case .curious: return 17
        case .playful: return 13
        case .happy: return 14
        case .neutral: return 16
        }
    }

    private var verticalScaleForEmotion: CGFloat {
        emotion == .waking ? 0.92 : 1.0
    }

    private var opacityForEmotion: Double {
        emotion == .sleeping ? 0.88 : 1.0
    }
}
