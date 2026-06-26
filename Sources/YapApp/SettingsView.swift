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
                    // Switch keys live: persist the selection and load that provider's key.
                    AppConfig.provider = newValue
                    apiKey = APIKeyStore.loadAPIKey(for: newValue) ?? ""
                    status = ""
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
            }

            Section {
                Text("Hotkey: ⌥S (Option+S) to start / stop dictation.")
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
