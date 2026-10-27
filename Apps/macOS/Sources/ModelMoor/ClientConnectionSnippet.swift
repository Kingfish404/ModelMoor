import Foundation
import ModelMoorCore

enum ClientConnectionSnippet {
    static func environment(port: Int) -> String {
        "export OPENAI_BASE_URL='http://127.0.0.1:\(port)/v1'"
    }

    static func usesResponses(source: APIEndpointSource?, upstreamModel: String) -> Bool {
        guard source == .modelMoorSubscription else { return false }
        return upstreamModel.hasPrefix("codex/") || upstreamModel.hasPrefix("gpt-")
    }

    static func request(port: Int, model: String, requiresAPIKey: Bool, usesResponses: Bool = false) -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": true
        ]
        if usesResponses {
            body["input"] = [["role": "user", "content": [["type": "input_text", "text": "Hello"]]]]
            body["instructions"] = "Be helpful."
            body["store"] = false
        } else {
            body["messages"] = [["role": "user", "content": "Hello"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        let path = usesResponses ? "responses" : "chat/completions"
        var lines = ["curl --no-buffer 'http://127.0.0.1:\(port)/v1/\(path)'"]
        if requiresAPIKey {
            lines.append("  -H \"Authorization: Bearer ${OPENAI_API_KEY:?Set OPENAI_API_KEY first}\"")
        }
        lines.append("  -H 'Content-Type: application/json'")
        lines.append("  --data-raw \(shellQuote(json))")
        return lines.joined(separator: " \\\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}