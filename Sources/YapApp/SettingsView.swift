import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import YapCore

struct SettingsView: View {
    // Speech-to-text
    @State private var provider: TranscriptionProvider = AppConfig.provider
    @State private var apiKey: String = APIKeyStore.loadAPIKey(for: AppConfig.provider) ?? ""
    @State private var keyterms: String = AppConfig.loadKeytermsRaw()
    @State private var noVerbatim: Bool = AppConfig.noVerbatim
    @State private var language: String = AppConfig.language
    @State private var status: String = ""

    /// Languages offered for Deepgram, mirroring Nova-3's supported set (BCP-47 codes
    /// from Deepgram's Models & Languages page). "multi" is multilingual code-switching
    /// — the default; the rest pin a single language for best accuracy. One entry per
    /// language (base code), plus the regional variants Deepgram lists as distinct.
    private static let languages: [(code: String, label: String)] = [
        ("multi", "Multilingual (auto)"),
        ("ar", "Arabic"),
        ("be", "Belarusian"),
        ("bn", "Bengali"),
        ("bs", "Bosnian"),
        ("bg", "Bulgarian"),
        ("ca", "Catalan"),
        ("zh", "Chinese (Mandarin, Simplified)"),
        ("zh-TW", "Chinese (Mandarin, Traditional)"),
        ("zh-HK", "Chinese (Cantonese)"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fi", "Finnish"),
        ("nl-BE", "Flemish"),
        ("fr", "French"),
        ("de", "German"),
        ("de-CH", "German (Switzerland)"),
        ("el", "Greek"),
        ("gu", "Gujarati"),
        ("he", "Hebrew"),
        ("hi", "Hindi"),
        ("hu", "Hungarian"),
        ("id", "Indonesian"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("kn", "Kannada"),
        ("ko", "Korean"),
        ("lv", "Latvian"),
        ("lt", "Lithuanian"),
        ("mk", "Macedonian"),
        ("ms", "Malay"),
        ("mr", "Marathi"),
        ("no", "Norwegian"),
        ("fa", "Persian"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sr", "Serbian"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("es", "Spanish"),
        ("sv", "Swedish"),
        ("tl", "Tagalog"),
        ("ta", "Tamil"),
        ("te", "Telugu"),
        ("th", "Thai"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("ur", "Urdu"),
        ("vi", "Vietnamese"),
    ]

    // General / permissions / microphone — refreshed on appear and on app activation
    // (never polled, so idle stays at ~0% CPU).
    @State private var launchAtLogin: Bool = false
    @State private var accessibilityGranted: Bool = false
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var inputDevices: [MicChoice] = []
    @State private var selectedDeviceUID: String = AppConfig.preferredInputDeviceUID ?? ""

    // Dictation hotkey
    @State private var hotKey: HotKeyShortcut = AppConfig.hotKey
    @State private var hotKeyStatus: String = ""

    // AI post-processing (Gemini)
    @State private var ppEnabled: Bool = AppConfig.postProcessEnabled
    @State private var ppAuth: GeminiAuthMethod = AppConfig.geminiAuthMethod
    @State private var ppModel: GeminiModel = AppConfig.postProcessModel
    @State private var ppPrompt: String = AppConfig.postProcessPrompt
    @State private var geminiKey: String = LLMCredentialStore.loadGeminiAPIKey() ?? ""
    @State private var vertexProject: String = AppConfig.vertexProject
    @State private var vertexRegion: String = AppConfig.vertexRegion
    @State private var ppStatus: String = ""

    // Local engine (Parakeet) setup state
    @ObservedObject private var parakeet = ParakeetManager.shared

    @ViewBuilder
    private var parakeetSetup: some View {
        switch parakeet.phase {
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fileFraction)
                Text("Downloading model — \(p.label)").font(.caption).foregroundStyle(.secondary)
            }
        case .checkingTools, .cloning, .building:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Building the engine on your Mac…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ \(msg)").font(.caption).foregroundStyle(Color.red)
                Button("Retry") { Task { await parakeet.ensureReady() } }
            }
        case .ready:
            Label("On-device engine ready", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .idle:
            if parakeet.isReady {
                Label("On-device engine ready", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runs fully on your Mac — no API key, no network. First-time setup builds the engine (needs Rust/cargo) and downloads ~670 MB.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Set up Parakeet") { Task { await parakeet.ensureReady() } }
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            }

            Section("Dictation shortcut") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyRecorder(current: hotKey, onCapture: applyHotKey)
                        .frame(width: 130, height: 24)
                }
                if !hotKeyStatus.isEmpty {
                    Text(hotKeyStatus).font(.caption)
                        .foregroundStyle(hotKeyStatus.hasPrefix("✓") ? Color.secondary : Color.red)
                }
                Text("Click the field and press a key combo with ⌘/⌥/⌃/⇧. Press ⎋ to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to paste the transcript at your cursor.",
                    granted: accessibilityGranted,
                    action: grantAccessibility)
                permissionRow(
                    title: "Microphone",
                    detail: "Required to hear your dictation.",
                    granted: micStatus == .authorized,
                    action: grantMicrophone)
            }

            Section("Microphone") {
                Picker("Input device", selection: $selectedDeviceUID) {
                    ForEach(inputDevices) { choice in
                        Text(choice.label).tag(choice.uid)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, uid in
                    AppConfig.preferredInputDeviceUID = uid.isEmpty ? nil : uid
                    // The Parakeet daemon pins its mic at launch via --device, so a running
                    // daemon would keep using the old one. Stop it; the next dictation restarts
                    // it on the newly chosen device.
                    ParakeetManager.shared.stopDaemon()
                }
                Text("Built-in is the default: recording through AirPods would drop their music into call mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speech-to-text") {
                Picker("Provider", selection: $provider) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, newValue in
                    // Abandon any session still running on the previous engine before the hotkey
                    // route changes under it (otherwise: orphaned session, aura stuck, Mac awake).
                    DictationBridge.cancelActiveSession()
                    // Switch keys live: persist the selection and load that provider's key.
                    AppConfig.provider = newValue
                    apiKey = APIKeyStore.loadAPIKey(for: newValue) ?? ""
                    status = ""
                    // Switching away from Parakeet: shut its daemon down instead of leaving it
                    // running in the background holding the model in RAM.
                    if !newValue.isLocal { ParakeetManager.shared.stopDaemon() }
                }

                if provider.isLocal {
                    parakeetSetup
                } else {
                    SecureField(provider == .elevenLabs ? "xi-api-key" : "Deepgram API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if provider == .elevenLabs {
                        Toggle("Remove filler words (no_verbatim)", isOn: $noVerbatim)
                            .help("Strips “ehm”, false starts and hesitations for a cleaner transcript.")
                            .onChange(of: noVerbatim) { _, newValue in AppConfig.noVerbatim = newValue }
                    }

                    if provider == .deepgram {
                        Picker("Language", selection: $language) {
                            ForEach(Self.languages, id: \.code) { lang in
                                Text(lang.label).tag(lang.code)
                            }
                        }
                        // Persist immediately so the choice sticks without needing Save & Verify
                        // (it used to revert to the default on reopen).
                        .onChange(of: language) { _, newValue in AppConfig.language = newValue }
                        .help("Deepgram assumes English without this — pick your language, or Multilingual to mix languages in one phrase. ElevenLabs auto-detects.")
                    }

                    HStack(spacing: 10) {
                        Button("Save & Verify") { saveAndVerify() }
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Custom dictionary (keyterms)") {
                Text("Up to 50 terms, ≤20 chars each. Comma or newline separated. Biases recognition toward these terms on both providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $keyterms)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    // Persist on every edit, like every other field here. Otherwise keyterms
                    // typed without then pressing "Save & Verify" are silently lost on close.
                    .onChange(of: keyterms) { _, v in AppConfig.saveKeytermsRaw(v) }
            }

            Section("AI cleanup") {
                Toggle("Clean up transcript with AI (Gemini)", isOn: $ppEnabled)
                    .onChange(of: ppEnabled) { _, v in AppConfig.postProcessEnabled = v }
                Text("Runs after every engine (including on-device Parakeet). On any error the raw transcript is pasted, so dictation is never lost.")
                    .font(.caption).foregroundStyle(.secondary)

                if ppEnabled {
                    Picker("Auth", selection: $ppAuth) {
                        Text("API key (AI Studio)").tag(GeminiAuthMethod.apiKey)
                        Text("Vertex (service account)").tag(GeminiAuthMethod.vertex)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: ppAuth) { _, v in AppConfig.geminiAuthMethod = v; ppStatus = "" }

                    if ppAuth == .apiKey {
                        SecureField("Gemini API key", text: $geminiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Button("Choose service-account JSON…") { pickServiceAccountJSON() }
                        if !vertexProject.isEmpty {
                            LabeledContent("Project", value: vertexProject)
                            HStack {
                                Text("Region")
                                TextField("us-central1", text: $vertexRegion)
                                    .textFieldStyle(.roundedBorder)
                                    // Persist on every edit, not only on Return — a Tab-away or
                                    // window close after editing must not drop the region. Trim so a
                                    // stray space/newline can't later break the Vertex URL.
                                    .onChange(of: vertexRegion) { _, v in
                                        AppConfig.vertexRegion = v.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                            }
                        }
                    }

                    Picker("Model", selection: $ppModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .onChange(of: ppModel) { _, v in AppConfig.postProcessModel = v }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ppPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                        HStack {
                            Button("Reset to default") { ppPrompt = PostProcessDefaults.prompt; AppConfig.postProcessPrompt = ppPrompt }
                            Spacer()
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Save & Verify") { saveAndVerifyGemini() }
                        Text(ppStatus).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Hotkey: \(hotKey.display) to start / stop dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 580)
        .onAppear(perform: refreshState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshState()
        }
    }

    // MARK: - Permission row

    @ViewBuilder
    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: action)
            }
        }
    }

    // MARK: - State refresh (no timers; called on appear / activation)

    private func refreshState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityGranted = AXIsProcessTrusted()
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        rebuildDeviceList()
    }

    private func rebuildDeviceList() {
        var choices: [MicChoice] = [MicChoice(uid: "", label: "Built-in microphone (default)")]
        let devices = AudioInputDevices.all()
        choices += devices
            .filter { !$0.isBuiltIn }
            .map { MicChoice(uid: $0.uid, label: $0.name) }
        // Keep a previously-chosen-but-now-absent device visible so the Picker still shows
        // the user's selection (capture transparently falls back to the built-in mic).
        if !selectedDeviceUID.isEmpty, !devices.contains(where: { $0.uid == selectedDeviceUID }) {
            choices.append(MicChoice(uid: selectedDeviceUID, label: "Previously selected mic (unavailable)"))
        }
        inputDevices = choices
    }

    // MARK: - Actions

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = service.status == .enabled
    }

    private func grantAccessibility() {
        // The prompting check adds Yap to the Accessibility list and shows the system
        // dialog when not yet trusted. Status updates once the user flips the switch and
        // returns to the app (didBecomeActive → refreshState).
        accessibilityGranted = Paster.promptForAccessibility()
    }

    private func grantMicrophone() {
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in refreshState() }
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    private func applyHotKey(_ candidate: HotKeyShortcut) {
        // The app actually registers it (it owns the HotKeyManager) and reports success.
        if HotKeyBridge.apply(candidate) {
            hotKey = candidate
            hotKeyStatus = "✓ Shortcut set to \(candidate.display)"
        } else {
            // Leave `hotKey` unchanged so the recorder reverts to the working shortcut.
            hotKeyStatus = "⚠️ \(candidate.display) is in use by another app — try another"
        }
    }

    private func pickServiceAccountJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let account = ServiceAccount(json: text) else {
            ppStatus = "✗ Not a service-account JSON (missing project_id/client_email)"
            return
        }
        LLMCredentialStore.saveVertexServiceAccountJSON(text)
        vertexProject = account.projectID
        AppConfig.vertexProject = account.projectID
        ppStatus = "✓ Service account loaded — project \(account.projectID)"
    }

    private func saveAndVerifyGemini() {
        AppConfig.postProcessEnabled = ppEnabled
        AppConfig.geminiAuthMethod = ppAuth
        AppConfig.postProcessModel = ppModel
        AppConfig.postProcessPrompt = ppPrompt
        AppConfig.vertexProject = vertexProject
        AppConfig.vertexRegion = vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if ppAuth == .apiKey { LLMCredentialStore.saveGeminiAPIKey(geminiKey) }
        ppStatus = "Verifying…"
        let settings = AppConfig.postProcessSettings()
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await GeminiKeyCheck.check(settings: settings, apiKey: key)
            await MainActor.run { ppStatus = result }
        }
    }

    private func saveAndVerify() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.provider = provider
        APIKeyStore.saveAPIKey(key, for: provider)
        AppConfig.saveKeytermsRaw(keyterms)
        AppConfig.noVerbatim = noVerbatim
        AppConfig.language = language
        // Only ElevenLabs has a lightweight key-check endpoint we use; for Deepgram we
        // just confirm the save (a bad key surfaces as an error on first dictation).
        guard provider == .elevenLabs else {
            status = key.isEmpty ? "✗ Empty key" : "✓ Saved"
            return
        }
        status = "Verifying…"
        Task {
            let result = await ElevenLabsKeyCheck.check(key)
            await MainActor.run { status = result }
        }
    }
}

/// One row in the microphone Picker. `uid` is the Core Audio UID we persist; an empty
/// uid means "follow the built-in mic" (the default).
private struct MicChoice: Identifiable, Hashable {
    let uid: String
    let label: String
    var id: String { uid }
}

enum GeminiKeyCheck {
    /// Sends a tiny real request through the configured processor; a non-throwing round-trip
    /// means the credential + endpoint work. Returns a short human-readable status.
    static func check(settings: PostProcessSettings, apiKey: String) async -> String {
        let processor: TextPostProcessor
        switch settings.authMethod {
        case .apiKey:
            guard !apiKey.isEmpty else { return "✗ Empty key" }
            processor = GeminiPostProcessor(model: settings.model, prompt: "Reply with: ok", auth: .apiKey(apiKey))
        case .vertex:
            guard let json = LLMCredentialStore.loadVertexServiceAccountJSON(),
                  let account = ServiceAccount(json: json), !settings.vertexProject.isEmpty else {
                return "✗ Pick a service-account JSON first"
            }
            let auth = GoogleServiceAccountAuth(account: account)
            processor = GeminiPostProcessor(
                model: settings.model, prompt: "Reply with: ok",
                auth: .vertex(token: { try await auth.accessToken() },
                              project: settings.vertexProject,
                              region: settings.vertexRegion.isEmpty ? PostProcessDefaults.vertexRegion : settings.vertexRegion)
            )
        }
        do {
            _ = try await processor.process("ping")
            return "✓ Working — saved"
        } catch let e as GeminiPostProcessorError {
            if case .httpStatus(let code) = e { return "✗ Rejected (HTTP \(code))" }
            return "✗ Empty response"
        } catch {
            return "✗ \(Diag.describe(error))"
        }
    }
}

enum ElevenLabsKeyCheck {
    /// Validates the key with a lightweight authenticated GET, returning a short
    /// human-readable status. 200 = valid; 401 = wrong key; anything else reports
    /// the status code or network error.
    static func check(_ key: String) async -> String {
        guard !key.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            return "✗ Empty key"
        }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200: return "✓ Valid key — saved"
            case 401: return "✗ Invalid key (401)"
            default: return "✗ Unexpected response (\(code))"
            }
        } catch {
            return "✗ Network error"
        }
    }
}
