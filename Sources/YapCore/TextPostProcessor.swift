import Foundation

/// Cleans/formats a finished transcript before it is pasted. Provider-agnostic so other
/// backends (e.g. OpenAI) can be added later without touching callers.
public protocol TextPostProcessor: Sendable {
    func process(_ text: String) async throws -> String
}
