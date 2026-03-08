import Foundation

enum LooiFaceCodeMap {
    static let primaryCodeByEmotion: [FaceEmotion: String] = [
        .sleeping: "003601",
        .waking: "002201",
        .neutral: "003401",
        .listening: "011601",
        .speaking: "010501",
        .moving: "004901",
        .happy: "003101",
        .love: "005801",
        .wink: "005901",
        .scared: "003301",
        .surprised: "002301",
        .sad: "004201",
        .angry: "001901",
        .dizzy: "N01445",
        .curious: "004501",
        .playful: "004301",
    ]

    static let emotionByCode: [String: FaceEmotion] = [
        "003601": .sleeping,
        "006801": .sleeping,
        "004401": .sleeping,
        "002201": .waking,
        "N01432": .waking,
        "003401": .neutral,
        "002001": .neutral,
        "005101": .neutral,
        "006001": .neutral,
        "006401": .neutral,
        "011601": .listening,
        "001701": .listening,
        "010501": .speaking,
        "004901": .moving,
        "003101": .happy,
        "003001": .happy,
        "004101": .happy,
        "004301": .happy,
        "005801": .love,
        "013901": .love,
        "014001": .love,
        "005901": .wink,
        "003301": .scared,
        "002301": .surprised,
        "004701": .surprised,
        "004201": .sad,
        "N01549": .sad,
        "001901": .angry,
        "001401": .angry,
        "N01445": .dizzy,
        "011501": .dizzy,
        "004501": .curious,
        "026301": .curious,
        "007401": .playful,
        "007501": .playful,
        "007601": .playful,
    ]

    static func emotion(for code: String?) -> FaceEmotion? {
        guard let code else { return nil }
        return emotionByCode[code]
    }

    static func code(for emotion: FaceEmotion) -> String? {
        primaryCodeByEmotion[emotion]
    }
}
