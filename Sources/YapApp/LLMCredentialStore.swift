import Foundation
import Security

/// Keychain storage for LLM (post-processing) secrets, on services SEPARATE from the STT
/// APIKeyStore: the Gemini AI-Studio API key and the Vertex service-account JSON. Same
/// generic-password pattern as APIKeyStore (encrypted at rest, not readable via `defaults`).
enum LLMCredentialStore {
    private static let account = "api-key"
    private static let geminiKeyService = "com.yap.gemini-api-key"
    private static let vertexSAService = "com.yap.gemini-vertex-sa"

    static func saveGeminiAPIKey(_ value: String) { save(value, service: geminiKeyService) }
    static func loadGeminiAPIKey() -> String? { load(service: geminiKeyService) }
    static func saveVertexServiceAccountJSON(_ value: String) { save(value, service: vertexSAService) }
    static func loadVertexServiceAccountJSON() -> String? { load(service: vertexSAService) }

    private static func save(_ value: String, service: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // empty = cleared
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}
