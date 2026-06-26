import Foundation

public enum GeminiWireError: Error, Equatable {
    case noCandidateText
}

/// Builds the `generateContent` request body and parses its response. The body is identical
/// for the API-key and Vertex endpoints — only the URL and auth header differ (see
/// GeminiPostProcessor).
public enum GeminiWire {
    public static func requestBody(prompt: String, transcript: String) throws -> Data {
        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": prompt]]],
            "contents": [["role": "user", "parts": [["text": transcript]]]],
            "generationConfig": ["temperature": 0],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func parseText(_ data: Data) throws -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw GeminiWireError.noCandidateText }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiWireError.noCandidateText }
        return trimmed
    }
}
