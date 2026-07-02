import Foundation
import Security

/// Keychain storage for LLM (post-processing) secrets, on services SEPARATE from the STT
/// APIKeyStore: the Gemini AI-Studio API key and the Vertex service-account JSON. Same
/// generic-password pattern as APIKeyStore (encrypted at rest, not readable via `defaults`).
enum LLMCredentialStore {
    private static let account = "api-key"
    private static let geminiKeyService = "com.yap.gemini-api-key"
    private static let vertexSAService = "com.yap.gemini-vertex-sa"

    @discardableResult
    static func saveGeminiAPIKey(_ value: String) -> Bool {
        KeychainStore.save(value, service: geminiKeyService, account: account)
    }
    static func loadGeminiAPIKey() -> String? { load(service: geminiKeyService) }

    @discardableResult
    static func saveVertexServiceAccountJSON(_ value: String) -> Bool {
        KeychainStore.save(value, service: vertexSAService, account: account)
    }
    static func loadVertexServiceAccountJSON() -> String? { load(service: vertexSAService) }

    private static func load(service: String) -> String? {
        if case .found(let value) = KeychainStore.read(service: service, account: account) {
            return value
        }
        return nil
    }
}
