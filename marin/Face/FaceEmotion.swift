import Foundation

enum FaceEmotion: String {
    case sleeping
    case waking
    case neutral
    case listening
    case speaking
    case moving
    case happy
    case love
    case wink
    case scared
    case surprised
    case sad
    case angry
    case dizzy
    case curious
    case playful

    static func from(_ value: String?) -> FaceEmotion? {
        guard let value else { return nil }
        return FaceEmotion(rawValue: value.lowercased())
    }
}
