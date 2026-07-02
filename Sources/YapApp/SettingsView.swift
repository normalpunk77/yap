import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import YapCore

struct SettingsView: View {
    // Speech-to-text
    @State private var provider: TranscriptionProvider = AppConfig.provider
    @State private var apiKey: String = APIKeyStore.loadAPIKey(for: AppConfig.provider) ?? ""
    // True only when the field actually SHOWED the stored key. Clearing-to-remove must
    // require it: with the Keychain locked at open, the field starts empty even though
    // a key exists — a save then must not silently delete a key the user never saw.
    @State private var storedKeyShownInField: Bool = APIKeyStore.loadAPIKey(for: AppConfig.provider) != nil
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
    @State private var launchAtLoginStatus: String = ""
    @State private var accessibilityGranted: Bool = false
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var inputDevices: [MicChoice] = []
    @State private var selectedDeviceUID: String = AppConfig.preferredInputDeviceUID ?? ""
    @State private var deviceStatus: String = ""

    // Dictation hotkey
    @State private var hotKey: HotKeyShortcut = AppConfig.hotKey
    @State private var hotKeyStatus: String = ""

    // AI post-processing (Gemini)
    @State private var ppEnabled: Bool = AppConfig.postProcessEnabled
    @State private var ppAuth: GeminiAuthMethod = AppConfig.geminiAuthMethod
    @State private var ppModel: GeminiModel = AppConfig.postProcessModel
    @State private var ppPrompt: String = AppConfig.postProcessPrompt
    @State private var geminiKey: String = LLMCredentialStore.loadGeminiAPIKey() ?? ""
    @State private var vertexServiceAccountJSON: String = LLMCredentialStore.loadVertexServiceAccountJSON() ?? ""
    @State private var vertexProject: String = AppConfig.vertexProject
    @State private var vertexRegion: String = AppConfig.vertexRegion
    @State private var ppStatus: String = ""
    @State private var sttVerificationGeneration: UInt64 = 0
    @State private var ppVerificationGeneration: UInt64 = 0
    @State private var sttVerificationTask: Task<Void, Never>?
    @State private var ppVerificationTask: Task<Void, Never>?

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
                if !launchAtLoginStatus.isEmpty {
                    Text(launchAtLoginStatus)
                        .font(.caption)
                        .foregroundStyle(launchAtLoginStatus.hasPrefix("⚠️") ? Color.red : .secondary)
                }
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
                    let dictationBusy = !DictationBridge.canSwitchProvider()
                    guard !SettingsInteractionPolicy.shouldBlockInputDeviceChange(
                        providerIsLocal: provider.isLocal,
                        dictationBusy: dictationBusy
                    ) else {
                        selectedDeviceUID = AppConfig.preferredInputDeviceUID ?? ""
                        deviceStatus = "Stop dictation before changing the input device"
                        return
                    }
                    AppConfig.preferredInputDeviceUID = uid.isEmpty ? nil : uid
                    deviceStatus = ""
                    // The Parakeet daemon pins its mic at launch via --device, so a running
                    // daemon would keep using the old one. Stop it; the next dictation restarts
                    // it on the newly chosen device.
                    ParakeetManager.shared.stopDaemon()
                }
                Text("Built-in is the default: recording through AirPods would drop their music into call mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !deviceStatus.isEmpty {
                    Text(deviceStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech-to-text") {
                Picker("Provider", selection: $provider) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, newValue in
                    // Draft-only selection: the real provider changes only after a
                    // successful Save & Verify.
                    apiKey = APIKeyStore.loadAPIKey(for: newValue) ?? ""
                    storedKeyShownInField = !apiKey.isEmpty
                    status = ""
                    deviceStatus = ""
                }

                if provider.isLocal {
                    parakeetSetup
                    // The picker above is draft-only (nothing commits without an explicit
                    // action) — without this button the local engine could never become
                    // the ACTIVE provider: the only commit path lived in the cloud branch.
                    HStack(spacing: 10) {
                        Button("Use on-device engine") { saveAndVerify() }
                            .disabled(!parakeet.isReady)
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    if !parakeet.isReady {
                        Text("Finish the setup above, then activate it here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    SecureField(provider == .elevenLabs ? "xi-api-key" : "Deepgram API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if provider == .elevenLabs {
                        Toggle("Remove filler words (no_verbatim)", isOn: $noVerbatim)
                            .help("Strips “ehm”, false starts and hesitations for a cleaner transcript.")
                            // Not a credential: persist on change. Behind Save & Verify it
                            // silently evaporated whenever the user didn't (re)verify a key.
                            .onChange(of: noVerbatim) { _, on in AppConfig.noVerbatim = on }
                    }

                    if provider == .deepgram {
                        Picker("Language", selection: $language) {
                            ForEach(Self.languages, id: \.code) { lang in
                                Text(lang.label).tag(lang.code)
                            }
                        }
                        .help("Deepgram assumes English without this — pick your language, or Multilingual to mix languages in one phrase. ElevenLabs auto-detects.")
                        .onChange(of: language) { _, code in AppConfig.language = code }
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
                    // Not a credential: persist as typed. It only committed behind a
                    // successful cloud-key verification — edits were silently lost for
                    // the local engine (no verify button at all) or on a failed verify.
                    .onChange(of: keyterms) { _, raw in AppConfig.saveKeytermsRaw(raw) }
            }

            Section("AI cleanup") {
                Toggle("Clean up transcript with AI (Gemini)", isOn: $ppEnabled)
                    // The on/off switch must stick IMMEDIATELY. It only persisted inside
                    // a successful Save & Verify — which is hidden when the section
                    // collapses on OFF — so disabling never stuck and every transcript
                    // kept flowing to Gemini against the user's explicit choice.
                    .onChange(of: ppEnabled) { _, on in AppConfig.postProcessEnabled = on }
                Text("Runs after every engine (including on-device Parakeet). On any error the raw transcript is pasted, so dictation is never lost.")
                    .font(.caption).foregroundStyle(.secondary)

                if ppEnabled {
                    Picker("Auth", selection: $ppAuth) {
                        Text("API key (AI Studio)").tag(GeminiAuthMethod.apiKey)
                        Text("Vertex (service account)").tag(GeminiAuthMethod.vertex)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: ppAuth) { _, _ in ppStatus = "" }

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
                            }
                        }
                    }

                    Picker("Model", selection: $ppModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ppPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                        HStack {
                            Button("Reset to default") { ppPrompt = PostProcessDefaults.prompt }
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
        deviceStatus = ""
        vertexServiceAccountJSON = SettingsDraftMerger.refreshedVertexServiceAccountJSON(
            currentDraft: vertexServiceAccountJSON,
            persisted: LLMCredentialStore.loadVertexServiceAccountJSON()
        )
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
            launchAtLoginStatus = on ? "✓ Launch at login enabled" : "✓ Launch at login disabled"
        } catch {
            launchAtLoginStatus = "⚠️ Couldn't update launch at login (\(error.localizedDescription))"
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
        vertexServiceAccountJSON = text
        ppAuth = .vertex
        vertexProject = account.projectID
        ppStatus = "✓ Service account loaded — ready to verify"
    }

    private func saveAndVerifyGemini() {
        let selectedAuth = ppAuth
        ppVerificationGeneration &+= 1
        let generation = ppVerificationGeneration
        ppVerificationTask?.cancel()
        ppStatus = "Verifying…"
        let settings = PostProcessSettings(
            enabled: ppEnabled,
            authMethod: selectedAuth,
            model: ppModel,
            prompt: ppPrompt,
            vertexProject: vertexProject,
            vertexRegion: vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ppVerificationTask = Task {
            let result = await GeminiKeyCheck.check(
                settings: settings,
                apiKey: key,
                serviceAccountJSON: vertexServiceAccountJSON
            )
            await MainActor.run {
                guard generation == ppVerificationGeneration else { return }
                var credentialPersisted = true
                SettingsSaveCoordinator.commitIfVerified(result) {
                    AppConfig.postProcessEnabled = ppEnabled
                    AppConfig.geminiAuthMethod = selectedAuth
                    AppConfig.postProcessModel = ppModel
                    AppConfig.postProcessPrompt = ppPrompt
                    AppConfig.vertexProject = vertexProject
                    AppConfig.vertexRegion = settings.vertexRegion
                    if selectedAuth == .apiKey {
                        credentialPersisted = LLMCredentialStore.saveGeminiAPIKey(key)
                    } else {
                        credentialPersisted = LLMCredentialStore.saveVertexServiceAccountJSON(vertexServiceAccountJSON)
                    }
                }
                ppStatus = credentialPersisted ? result
                    : "⚠️ Verified but the Keychain refused to save the credential — unlock the login keychain and retry"
                ppVerificationTask = nil
            }
        }
    }

    private func saveAndVerify() {
        let selectedProvider = provider
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if SettingsInteractionPolicy.shouldBlockProviderCommit(
            current: AppConfig.provider,
            selected: selectedProvider,
            dictationBusy: !DictationBridge.canSwitchProvider()
        ) {
            status = "Stop dictation before switching providers"
            return
        }
        // Clearing the field + Save = remove the stored key. Verification would just
        // report "Empty key" and leave the secret in the Keychain forever. Only when
        // the field actually SHOWED the stored key: an empty field caused by a locked
        // Keychain at open must not delete a key the user never saw.
        if key.isEmpty, !selectedProvider.isLocal, storedKeyShownInField,
           APIKeyStore.loadAPIKey(for: selectedProvider) != nil {
            status = APIKeyStore.saveAPIKey("", for: selectedProvider)
                ? "✓ Key removed"
                : "⚠️ The Keychain refused to remove the key"
            return
        }
        sttVerificationGeneration &+= 1
        let generation = sttVerificationGeneration
        sttVerificationTask?.cancel()
        status = "Verifying…"
        sttVerificationTask = Task {
            let result: String
            switch selectedProvider {
            case .elevenLabs:
                result = await ElevenLabsKeyCheck.check(key)
            case .deepgram:
                result = await DeepgramKeyCheck.check(key)
            case .parakeetLocal:
                result = STTSettingsSaveCoordinator.verificationResult(for: selectedProvider)
            }
            await MainActor.run {
                guard generation == sttVerificationGeneration else { return }
                var keyPersisted = true
                SettingsSaveCoordinator.commitIfVerified(result) {
                    AppConfig.provider = selectedProvider
                    if STTSettingsSaveCoordinator.shouldPersistAPIKey(for: selectedProvider) {
                        keyPersisted = APIKeyStore.saveAPIKey(key, for: selectedProvider)
                    }
                    AppConfig.saveKeytermsRaw(keyterms)
                    AppConfig.noVerbatim = noVerbatim
                    AppConfig.language = language
                }
                // Never show the green check over a key that isn't actually stored.
                status = keyPersisted ? result
                    : "⚠️ Key verified but the Keychain refused to save it — unlock the login keychain and retry"
                sttVerificationTask = nil
            }
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

enum SettingsDraftMerger {
    static func refreshedVertexServiceAccountJSON(currentDraft: String, persisted: String?) -> String {
        currentDraft.isEmpty ? (persisted ?? "") : currentDraft
    }
}

enum GeminiKeyCheck {
    /// Sends a tiny real request through the configured processor; a non-throwing round-trip
    /// means the credential + endpoint work. Returns a short human-readable status.
    static func check(
        settings: PostProcessSettings,
        apiKey: String,
        serviceAccountJSON: String? = nil
    ) async -> String {
        let session = verificationSession()
        let processor: TextPostProcessor
        switch settings.authMethod {
        case .apiKey:
            guard !apiKey.isEmpty else { return "✗ Empty key" }
            processor = GeminiPostProcessor(
                model: settings.model,
                prompt: "Reply with: ok",
                auth: .apiKey(apiKey),
                session: session
            )
        case .vertex:
            guard let json = serviceAccountJSON ?? LLMCredentialStore.loadVertexServiceAccountJSON(),
                  let account = ServiceAccount(json: json), !settings.vertexProject.isEmpty else {
                return "✗ Pick a service-account JSON first"
            }
            let auth = GoogleServiceAccountAuth(account: account, session: session)
            processor = GeminiPostProcessor(
                model: settings.model, prompt: "Reply with: ok",
                auth: .vertex(token: { try await auth.accessToken() },
                              project: settings.vertexProject,
                              region: settings.vertexRegion.isEmpty ? PostProcessDefaults.vertexRegion : settings.vertexRegion),
                session: session
            )
        }
        do {
            _ = try await processor.process("ping")
            return "✓ Working — saved"
        } catch let e as GeminiPostProcessorError {
            switch e {
            case .httpStatus(let code): return "✗ Rejected (HTTP \(code))"
            case .badURL: return "✗ Invalid Vertex region — check the Region field"
            case .emptyResponse: return "✗ Empty response"
            }
        } catch {
            return "✗ \(Diag.describe(error))"
        }
    }

    private static func verificationSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }
}

enum ElevenLabsKeyCheck {
    /// Validates the key with a lightweight authenticated GET, returning a short
    /// human-readable status. 200 = valid; 401 = wrong key; anything else reports
    /// the status code or network error.
    static func check(_ key: String, session: URLSession = URLSession(configuration: .ephemeral)) async -> String {
        guard !key.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            return "✗ Empty key"
        }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await session.data(for: req)
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

enum DeepgramKeyCheck {
    /// Validates the key with a lightweight authenticated GET against Deepgram's projects API.
    /// 200 = valid; 401 = wrong key; anything else reports the status code or network error.
    static func check(_ key: String, session: URLSession = URLSession(configuration: .ephemeral)) async -> String {
        guard !key.isEmpty, let url = URL(string: "https://api.deepgram.com/v1/projects") else {
            return "✗ Empty key"
        }
        var req = URLRequest(url: url)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await session.data(for: req)
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
