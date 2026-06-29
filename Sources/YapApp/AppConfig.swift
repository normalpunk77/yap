import Foundation
import YapCore

/// Non-secret dictation settings, persisted in UserDefaults.
enum AppConfig {
    private static let legacyDefaultsBundleID = "com.yap.Yap"
    private static let keytermsKey = "keyterms"
    private static let noVerbatimKey = "no_verbatim"
    private static let providerKey = "stt_provider"
    private static let inputDeviceUIDKey = "input_device_uid"
    private static let languageKey = "stt_language"
    private static let hotKeyCodeKey = "hotkey_keycode"
    private static let hotKeyModsKey = "hotkey_modifiers"
    private static let hotKeyLabelKey = "hotkey_label"
    private static let postProcEnabledKey = "postproc_enabled"
    private static let postProcModelKey = "postproc_model"
    private static let postProcPromptKey = "postproc_prompt"
    private static let geminiAuthMethodKey = "gemini_auth_method"
    private static let vertexProjectKey = "vertex_project"
    private static let vertexRegionKey = "vertex_region"
    private static let keytermsCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKeytermsRaw = defaultKeytermsRaw
    nonisolated(unsafe) private static var cachedKeyterms = [String]()

    static func migrateLegacyUserDefaults() {
        guard let legacy = UserDefaults(suiteName: legacyDefaultsBundleID) else { return }
        migrateLegacyUserDefaults(from: legacy.dictionaryRepresentation())
    }

    static func migrateLegacyUserDefaults(from legacyValues: [String: Any]) {
        guard !legacyValues.isEmpty else { return }

        let defaults = UserDefaults.standard
        for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: Dictation hotkey

    /// The user-chosen global hotkey that toggles dictation. Defaults to ⌥S until the user
    /// records a different one in Settings. Persisted as its raw Carbon keyCode/modifiers
    /// plus a display label.
    static var hotKey: HotKeyShortcut {
        get {
            let d = UserDefaults.standard
            // Require BOTH halves to be present. The three keys are written separately; a process
            // killed mid-save could leave only the keyCode, yielding a modifier-less shortcut that
            // registers a bare key globally and swallows every press of that character.
            guard d.object(forKey: hotKeyCodeKey) != nil,
                  d.object(forKey: hotKeyModsKey) != nil else { return .defaultShortcut }
            return HotKeyShortcut(
                keyCode: UInt32(d.integer(forKey: hotKeyCodeKey)),
                modifiers: UInt32(d.integer(forKey: hotKeyModsKey)),
                keyLabel: d.string(forKey: hotKeyLabelKey) ?? "?")
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.keyCode), forKey: hotKeyCodeKey)
            d.set(Int(newValue.modifiers), forKey: hotKeyModsKey)
            d.set(newValue.keyLabel, forKey: hotKeyLabelKey)
        }
    }

    // MARK: Language

    /// Spoken-language hint for the STT provider, as a Deepgram language code. Defaults
    /// to "multi" (Nova-3 multilingual code-switching) so Italian mixed with English tech
    /// terms transcribes correctly — without it Deepgram assumes English and garbles
    /// other languages. ElevenLabs auto-detects and ignores this.
    static var language: String {
        get { UserDefaults.standard.string(forKey: languageKey) ?? "multi" }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    // MARK: Microphone

    /// The user's chosen microphone, stored as its stable Core Audio UID. `nil` means
    /// "follow the built-in mic" — the default that keeps a Bluetooth headset in music
    /// mode (see MicrophoneCapture). A device that later disappears falls back to built-in.
    static var preferredInputDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: inputDeviceUIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: inputDeviceUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: inputDeviceUIDKey)
            }
        }
    }

    // MARK: Provider

    /// The active speech-to-text provider. Defaults to ElevenLabs.
    static var provider: TranscriptionProvider {
        get { TranscriptionProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .elevenLabs }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    // MARK: Custom dictionary (keyterms)

    /// Ships EMPTY: Yap is a generic tool, so out of the box it biases recognition
    /// toward nothing. Users add their own terms in Settings; a saved empty value is
    /// respected (the +20% keyterms cost stays avoidable until you opt in).
    static let defaultKeytermsRaw = ""

    static func saveKeytermsRaw(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: keytermsKey)
        keytermsCacheLock.lock()
        cachedKeytermsRaw = raw
        cachedKeyterms = parsedKeyterms(from: raw)
        keytermsCacheLock.unlock()
    }

    /// Falls back to `defaultKeytermsRaw` only when nothing was ever saved (nil).
    /// A saved empty string is preserved so the user can opt out of keyterms.
    static func loadKeytermsRaw() -> String {
        UserDefaults.standard.string(forKey: keytermsKey) ?? defaultKeytermsRaw
    }

    /// Parsed terms ready for the WS query: comma/newline separated, trimmed,
    /// each capped at 20 characters, max 50 terms (ElevenLabs limits).
    static func keyterms() -> [String] {
        let raw = loadKeytermsRaw()
        keytermsCacheLock.lock()
        defer { keytermsCacheLock.unlock() }
        if raw == cachedKeytermsRaw { return cachedKeyterms }
        let terms = parsedKeyterms(from: raw)
        cachedKeytermsRaw = raw
        cachedKeyterms = terms
        return terms
    }

    private static func parsedKeyterms(from raw: String) -> [String] {
        let terms = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(20)) }
        return Array(terms.prefix(50))
    }

    // MARK: no_verbatim (strip filler words)

    /// Defaults to true — a cleaner transcript is the better default for dictation.
    static var noVerbatim: Bool {
        get { UserDefaults.standard.object(forKey: noVerbatimKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: noVerbatimKey) }
    }

    // MARK: AI post-processing (Gemini)

    /// Master switch for the AI cleanup pass. Ships OFF — it requires a credential and sends
    /// the transcript to Gemini, so it must be an explicit opt-in.
    static var postProcessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: postProcEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: postProcEnabledKey) }
    }

    static var geminiAuthMethod: GeminiAuthMethod {
        get { GeminiAuthMethod(rawValue: UserDefaults.standard.string(forKey: geminiAuthMethodKey) ?? "") ?? .apiKey }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: geminiAuthMethodKey) }
    }

    static var postProcessModel: GeminiModel {
        get { GeminiModel(rawValue: UserDefaults.standard.string(forKey: postProcModelKey) ?? "") ?? .flashLite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: postProcModelKey) }
    }

    /// Falls back to the curated default only when nothing was ever saved. A saved empty
    /// string would be respected, but the UI prevents saving empty (Reset restores default).
    static var postProcessPrompt: String {
        get { UserDefaults.standard.string(forKey: postProcPromptKey) ?? PostProcessDefaults.prompt }
        set { UserDefaults.standard.set(newValue, forKey: postProcPromptKey) }
    }

    static var vertexProject: String {
        get { UserDefaults.standard.string(forKey: vertexProjectKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: vertexProjectKey) }
    }

    static var vertexRegion: String {
        get { UserDefaults.standard.string(forKey: vertexRegionKey) ?? PostProcessDefaults.vertexRegion }
        set { UserDefaults.standard.set(newValue, forKey: vertexRegionKey) }
    }

    static func postProcessSettings() -> PostProcessSettings {
        PostProcessSettings(
            enabled: postProcessEnabled,
            authMethod: geminiAuthMethod,
            model: postProcessModel,
            prompt: postProcessPrompt,
            vertexProject: vertexProject,
            vertexRegion: vertexRegion
        )
    }
}
