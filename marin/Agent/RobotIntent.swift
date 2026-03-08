import Foundation

struct RobotIntent: Decodable {
    struct Motion: Decodable {
        let type: String?
        let forward: Double?
        let veer: Double?
        let durationMs: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case forward
            case veer
            case durationMs = "duration_ms"
        }
    }

    struct Head: Decodable {
        let type: String?
    }

    let command: String?
    let emotion: String?
    let emotionCode: String?
    let motion: Motion?
    let head: Head?

    enum CodingKeys: String, CodingKey {
        case command
        case emotion
        case emotionCode = "emotion_code"
        case motion
        case head
    }
}

enum RobotIntentParser {
    static func parse(from text: String) -> RobotIntent? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        let json = String(text[start ... end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RobotIntent.self, from: data)
    }
}
