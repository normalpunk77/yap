import Foundation

/// Which Gemini credential style the post-processor uses. Both are the user's own
/// credential (BYOK); nothing routes through a server of ours.
public enum GeminiAuthMethod: String, CaseIterable, Sendable {
    case apiKey   // AI Studio key on generativelanguage.googleapis.com
    case vertex   // service-account JSON on {region}-aiplatform.googleapis.com
}

/// The lightweight Gemini models offered for cleanup.
public enum GeminiModel: String, CaseIterable, Sendable {
    case flashLite = "gemini-2.5-flash-lite"
    case flash = "gemini-2.5-flash"

    public var displayName: String {
        switch self {
        case .flashLite: return "Gemini 2.5 Flash Lite"
        case .flash: return "Gemini 2.5 Flash"
        }
    }
}

/// Non-secret post-processing configuration. Secrets (API key, SA JSON) are passed to the
/// processor separately, never stored here.
public struct PostProcessSettings: Sendable, Equatable {
    public var enabled: Bool
    public var authMethod: GeminiAuthMethod
    public var model: GeminiModel
    public var prompt: String
    public var vertexProject: String
    public var vertexRegion: String

    public init(
        enabled: Bool,
        authMethod: GeminiAuthMethod,
        model: GeminiModel,
        prompt: String,
        vertexProject: String,
        vertexRegion: String
    ) {
        self.enabled = enabled
        self.authMethod = authMethod
        self.model = model
        self.prompt = prompt
        self.vertexProject = vertexProject
        self.vertexRegion = vertexRegion
    }
}

public enum PostProcessDefaults {
    public static let vertexRegion = "us-central1"

    /// The curated cleanup instruction. The user can overwrite this entirely in Settings to
    /// change the LLM's behavior.
    public static let prompt = """
    You are a transcription cleanup engine. Fix punctuation, capitalization, and obvious \
    spacing. Remove filler words and false starts. Keep the speaker's exact words, meaning, \
    and language unchanged — do not translate, summarize, answer, or add anything. Output \
    only the cleaned text, with no preamble or quotes.
    """
}
