import Foundation

struct RealtimeAgentConfig {
    let endpoint: String
    let apiKey: String
    let deployment: String

    init() {
        self.endpoint = SecretsManager.value(forKey: "AZURE_OPENAI_ENDPOINT")
        self.apiKey = SecretsManager.value(forKey: "AZURE_OPENAI_API_KEY")
        self.deployment = SecretsManager.value(forKey: "AZURE_OPENAI_REALTIME_DEPLOYMENT").isEmpty
            ? "gpt-realtime-1.5"
            : SecretsManager.value(forKey: "AZURE_OPENAI_REALTIME_DEPLOYMENT")
    }

    var isValid: Bool {
        !endpoint.isEmpty && !apiKey.isEmpty && !deployment.isEmpty
    }

    var websocketURL: URL? {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parsedHost: String? = {
            if raw.contains("://"), let comps = URLComponents(string: raw), let host = comps.host {
                return host
            }
            return raw
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .split(separator: "/")
                .first
                .map(String.init)
        }()

        guard let baseHost = parsedHost, !baseHost.isEmpty else { return nil }

        let host = baseHost
            .replacingOccurrences(of: ".cognitiveservices.azure.com", with: ".openai.azure.com")

        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = "/openai/v1/realtime"
        comps.queryItems = [URLQueryItem(name: "model", value: deployment)]
        return comps.url
    }
}
