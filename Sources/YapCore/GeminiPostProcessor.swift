import Foundation

public enum GeminiPostProcessorError: Error, Equatable {
    case httpStatus(Int)
    case emptyResponse
}

/// Calls Gemini's `generateContent` to clean a transcript. Two auth styles share the request
/// body (GeminiWire) and differ only in URL + auth header.
public struct GeminiPostProcessor: TextPostProcessor {
    /// `vertex.token` is an async closure that yields a fresh OAuth access token
    /// (GoogleServiceAccountAuth wires it here). Kept as a closure so this type stays free of
    /// Keychain.
    public enum Auth: Sendable {
        case apiKey(String)
        case vertex(token: @Sendable () async throws -> String, project: String, region: String)
    }

    private let model: GeminiModel
    private let prompt: String
    private let auth: Auth
    private let session: URLSession

    public init(model: GeminiModel, prompt: String, auth: Auth, session: URLSession = .shared) {
        self.model = model
        self.prompt = prompt
        self.auth = auth
        self.session = session
    }

    public func process(_ text: String) async throws -> String {
        let request = try await makeRequest(transcript: text)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw GeminiPostProcessorError.httpStatus(code) }
        return try GeminiWire.parseText(data)
    }

    private func makeRequest(transcript: String) async throws -> URLRequest {
        let body = try GeminiWire.requestBody(prompt: prompt, transcript: transcript)
        switch auth {
        case .apiKey(let key):
            // Pass the key as a header, NOT a `?key=` query param: a URL with the key embedded
            // leaks into crash reports (NSURLErrorFailingURLStringErrorKey) and proxy logs.
            let url = URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent")!
            var req = jsonPOST(url, body: body)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return req
        case .vertex(let token, let project, let region):
            let url = URL(string:
                "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model.rawValue):generateContent")!
            var req = jsonPOST(url, body: body)
            let accessToken = try await token()
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return req
        }
    }

    private func jsonPOST(_ url: URL, body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }
}
