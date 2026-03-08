import Foundation

enum SecretsManager {
    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return dict
    }()

    static func value(forKey key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? secrets[key] ?? ""
    }
}
