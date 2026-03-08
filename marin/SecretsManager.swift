import Foundation

enum SecretsManager {
    private static let cachePrefix = "marin.secret."

    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return dict
    }()

    static func value(forKey key: String) -> String {
        let env = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty {
            UserDefaults.standard.set(env, forKey: cachePrefix + key)
            return env
        }

        let plistValue = secrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !plistValue.isEmpty {
            UserDefaults.standard.set(plistValue, forKey: cachePrefix + key)
            return plistValue
        }

        return UserDefaults.standard.string(forKey: cachePrefix + key) ?? ""
    }

    static func missingKeys(_ keys: [String]) -> [String] {
        keys.filter { value(forKey: $0).isEmpty }
    }
}
