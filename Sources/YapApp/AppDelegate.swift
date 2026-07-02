import AppKit
import AVFoundation
import SwiftUI
import YapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var keyStatusItem: NSMenuItem!
    private var dictateHintItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private let edgeGlow = EdgeGlowHUD()         // the aura — the only recording indicator
    private let micCapture = MicrophoneCapture()
    // A second, level-only mic tap used ONLY during Parakeet dictation: the transcription mic
    // lives in the daemon (another process), so this is how the aura gets real voice levels to
    // react to. Independent of the daemon — if it can't start, the aura just self-breathes.
    private let parakeetMeter = MicrophoneCapture()
    private var hotKey: HotKeyManager!
    private var activeHotKey: HotKeyShortcut?    // the last shortcut that registered OK
    private var controller: DictationController!
    private let parakeetController = ParakeetController()
    private var dictationActivity: NSObjectProtocol?
    private var dictationSessionPending = false
    private var dictationSessionActive = false
    // Quit is in flight: suppress modal alerts (they'd hold .terminateLater hostage)
    // and fire the local-engine stop only once.
    private var isTerminating = false
    private var shutdownStopRequested = false
    // Last shortcut we already alerted about: resumeHotKey fires on every Settings
    // focus-loss, and re-alerting the SAME conflict each time is spam, not signal.
    private var lastConflictAlerted: HotKeyShortcut?
    // Persist the Vertex auth across dictations so its OAuth token cache survives. Rebuilding it
    // per dictation (as `makePostProcessor` did) threw the cache away and re-minted a token every
    // time — a JWT sign + token-exchange round trip to Google that dominated the cleanup latency.
    private var cachedVertexAuth: (account: ServiceAccount, auth: GoogleServiceAccountAuth)?
    private lazy var deliveryQueue = DeliveryQueue(
        makeProcessor: { [weak self] in self?.makePostProcessor() },
        // Await the paste's settle window so the queue can't write the next transcript
        // to the pasteboard while the previous ⌘V is still being consumed.
        paste: { text in
            if let settle = Paster.pasteAtCursor(text) { await settle.value }
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recover keys saved under the pre-rename bundle id so they don't appear lost after
        // upgrading, then wipe any plaintext keys older builds left in UserDefaults so nothing
        // sensitive lingers in a readable plist.
        AppConfig.migrateLegacyUserDefaults()
        APIKeyStore.migrateLegacyKeychainKeys()
        APIKeyStore.purgeLegacyPlaintextKeys()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        // Without an app main menu, the Settings window's text fields can't receive the
        // standard editing shortcuts: ⌘V/⌘C/⌘X/⌘A would just beep (no menu item matches
        // the key equivalent). Install a minimal Edit menu so pasting an API key works.
        installMainMenu()

        // The menu is intentionally minimal: everything configurable now lives in the
        // single Settings window. We keep only quick status, Settings and Quit.
        let menu = NSMenu()
        menu.delegate = self
        // Settings at the top, Quit isolated at the bottom behind separators, so the two
        // can't be hit interchangeably by accident.
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        dictateHintItem = NSMenuItem(title: dictateHintTitle(), action: nil, keyEquivalent: "")
        dictateHintItem.isEnabled = false
        menu.addItem(dictateHintItem)
        keyStatusItem = NSMenuItem(title: keyStatusTitle(), action: nil, keyEquivalent: "")
        keyStatusItem.isEnabled = false
        menu.addItem(keyStatusItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        configureLoginItem()

        let controller = DictationController(
            capturer: micCapture,
            clientFactory: {
                let provider = AppConfig.provider
                // The local engine (Parakeet) doesn't use this WebSocket client factory at
                // all — the hotkey routes it to ParakeetController instead. Guard anyway.
                guard !provider.isLocal else { throw AppError.localEngineHasNoClient }
                let key: String
                switch APIKeyStore.readAPIKey(for: provider) {
                case .found(let value):
                    key = value
                case .missing:
                    throw AppError.missingAPIKey
                case .failed:
                    // NOT the same as "no key": the key may well be there but the
                    // Keychain refused (locked, ACL denied after a signature change).
                    // Telling the user to enter a key would be a lie.
                    throw AppError.keychainUnavailable
                }
                switch provider {
                case .parakeetLocal:
                    throw AppError.localEngineHasNoClient   // unreachable (guarded above)
                case .elevenLabs:
                    let socket = URLSessionTranscriptionSocket.make(
                        apiKey: key,
                        keyterms: AppConfig.keyterms(),
                        noVerbatim: AppConfig.noVerbatim
                    )
                    return ElevenLabsRealtimeClient(socket: socket, sampleRate: 16000)
                case .deepgram:
                    let socket = URLSessionTranscriptionSocket.makeDeepgram(
                        apiKey: key,
                        keyterms: AppConfig.keyterms(),
                        language: AppConfig.language
                    )
                    return DeepgramRealtimeClient(socket: socket)
                }
            },
            // Keep the mic open ~0.25s after stop so a word spoken right up to the keypress is
            // still captured (its audio isn't recorded yet at the instant of the press).
            trailingCaptureSeconds: 0.25,
            // Safety-net cap on waiting for the provider's post-commit flush before delivering.
            // The final segment (or the decoded from_finalize ack) normally arrives on its own
            // (~0.5s) and delivers immediately — since the ack is decoded, this timeout fires
            // only when the network actually swallowed it. 2.0s keeps real margin for a lossy
            // link without re-introducing the old ~3s dead wait in the common case.
            finalizeTimeoutSeconds: 2.0
        )
        self.controller = controller

        micCapture.onLevel = { [weak self] level in
            DispatchQueue.main.async { [weak self] in self?.edgeGlow.updateLevel(level) }
        }
        // The input died irrecoverably mid-dictation (mic unplugged, no fallback came
        // up): end the session — salvaging the text dictated so far — instead of
        // sitting in `.listening` on a dead microphone.
        micCapture.onCaptureFailure = { [weak self] in
            guard let self else { return }
            Task { await self.controller.captureFailed() }
        }

        Task {
            await controller.setHandlers(
                onState: { state in
                    DispatchQueue.main.async { [weak self] in self?.render(state) }
                },
                onResult: { text in
                    DispatchQueue.main.async { [weak self] in self?.deliver(text: text) }
                }
            )
        }

        parakeetController.onRecording = { [weak self] on in self?.renderParakeet(recording: on) }
        parakeetController.onError = { [weak self] msg in
            self?.clearDictationSession()
            self?.presentError(msg)
        }
        parakeetController.onText = { [weak self] text in self?.deliver(text: text) }
        parakeetController.onSessionEnded = { [weak self] in self?.clearDictationSession() }

        hotKey = HotKeyManager(onTrigger: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.dictationSessionPending else { return }
                // Local engine (Parakeet) records via its daemon — a child process whose mic
                // access is attributed to Yap. So Yap itself must hold Microphone permission
                // before we start, or the daemon captures silence (and CoreAudio beeps). Only
                // gate on start; stopping needs no mic.
                if AppConfig.provider.isLocal {
                    if !self.parakeetController.isRecording {
                        guard !self.dictationSessionActive else { return }
                        self.beginDictationStartup()
                        guard await self.ensureMicrophoneAuthorized() else {
                            self.clearDictationSession()
                            return
                        }
                    }
                    await self.parakeetController.toggle()
                    return
                }
                // Mic denied earlier and macOS won't re-prompt on its own: guide the
                // user to re-enable it instead of silently failing to record.
                guard self.ensureMicrophoneAccess() else { return }
                switch await self.controller.state {
                case .idle, .error:
                    self.beginDictationStartup()
                case .listening, .finalizing:
                    break
                }
                await self.controller.toggle()
            }
        })
        // Register the user's chosen shortcut (⌥S by default). If the system rejects it —
        // another app already owns that combo — say so instead of failing silently.
        let initialHotKey = AppConfig.hotKey
        if hotKey.register(initialHotKey) {
            activeHotKey = initialHotKey
        } else {
            presentHotKeyConflict(initialHotKey)
        }
        // Let Settings (re)bind the shortcut and learn whether it took.
        HotKeyBridge.apply = { [weak self] shortcut in self?.applyHotKey(shortcut) ?? false }
        // Let Settings refuse provider switches while a session is starting or active. That
        // avoids orphaning or discarding the in-flight transcript.
        DictationBridge.canSwitchProvider = { [weak self] in
            guard let self else { return true }
            return !self.dictationSessionPending && !self.dictationSessionActive
        }

        // Register for Accessibility on launch so Yap shows up in System Settings →
        // Privacy → Accessibility only when the user actually tries to paste. That avoids an
        // intrusive permission prompt on first launch and keeps startup free of UX surprises.

        // A Dock-less accessory app is easy to "lose" — there's no window or Dock icon,
        // only the menu-bar glyph. Open Settings once, on the very first launch, so the
        // user can find and configure it. Afterwards it's reachable from the menu only.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            openSettings()
        }

        // Mint the Vertex OAuth token now, in the background, so the FIRST dictation's cleanup
        // doesn't pay the token round trip inline (the rest reuse the cached token). No-op for
        // API-key auth or when cleanup is disabled/unconfigured.
        prewarmVertexAuth()
    }

    /// If Vertex cleanup is configured, build the (cached) auth and fetch a token eagerly so the
    /// first cleanup is as fast as the rest. Best-effort: failures are ignored — the real
    /// dictation path mints on demand and falls back to the raw transcript on error.
    private func prewarmVertexAuth() {
        let s = AppConfig.postProcessSettings()
        guard s.enabled, s.authMethod == .vertex, !s.vertexProject.isEmpty,
              let json = LLMCredentialStore.loadVertexServiceAccountJSON(),
              let account = ServiceAccount(json: json)
        else { return }
        let auth = vertexAuth(for: account)
        Task.detached(priority: .utility) { _ = try? await auth.accessToken() }
    }

    private func deliver(text: String) {
        clearDictationSession()
        deliveryQueue.enqueue(text)
    }

    /// Build a Gemini post-processor from current settings + stored credentials, or nil when
    /// disabled or unconfigured (→ raw paste). Reads fresh each call so Settings changes apply
    /// to the next dictation without a restart.
    private func makePostProcessor() -> TextPostProcessor? {
        let s = AppConfig.postProcessSettings()
        guard s.enabled else { return nil }
        switch s.authMethod {
        case .apiKey:
            guard let key = LLMCredentialStore.loadGeminiAPIKey(), !key.isEmpty else { return nil }
            return GeminiPostProcessor(model: s.model, prompt: s.prompt, auth: .apiKey(key))
        case .vertex:
            guard
                let json = LLMCredentialStore.loadVertexServiceAccountJSON(),
                let account = ServiceAccount(json: json),
                !s.vertexProject.isEmpty
            else { return nil }
            let auth = vertexAuth(for: account)
            let region = s.vertexRegion.isEmpty ? PostProcessDefaults.vertexRegion : s.vertexRegion
            return GeminiPostProcessor(
                model: s.model, prompt: s.prompt,
                auth: .vertex(token: { try await auth.accessToken() },
                              project: s.vertexProject, region: region),
                // A 401/403 means the cached token died early (revoked, clock drift):
                // drop it so the next cleanup mints fresh instead of failing for the
                // rest of the token's local lifetime.
                onAuthFailure: { await auth.invalidateCachedToken() }
            )
        }
    }

    /// Reuse one auth actor per service account so its OAuth token cache survives across
    /// dictations (≈one token mint per hour, not one per dictation). Rebuilds only when the
    /// stored credentials actually change.
    private func vertexAuth(for account: ServiceAccount) -> GoogleServiceAccountAuth {
        if let cached = cachedVertexAuth, cached.account == account { return cached.auth }
        let auth = GoogleServiceAccountAuth(account: account)
        cachedVertexAuth = (account, auth)
        return auth
    }

    /// Drive the aura for the local-engine path (the cloud path uses `render(_:)`).
    private func renderParakeet(recording: Bool) {
        if recording {
            markDictationActive()
            beginDictationActivity()
            updateIcon(recording: true)
            // Show the aura immediately in self-breathing mode (no levels yet), then start a
            // parallel level meter so it reacts to the real voice once audio flows.
            edgeGlow.show(voiceReactive: false)
            startParakeetMeter()
        } else {
            endDictationActivity()
            updateIcon(recording: false)
            edgeGlow.hide()
            stopParakeetMeter()
        }
    }

    /// Drive the aura from a real mic level meter during Parakeet dictation. The daemon owns the
    /// transcription mic in another process; this independent tap exists only to give the aura
    /// the user's voice. Best-effort: on failure the aura keeps self-breathing.
    /// Serializes meter start/stop on ONE chain so they never overlap on the shared capturer.
    /// A bare `Task{start}` + `Task{stop}` (or stop awaiting only the latest start) lets a rapid
    /// stop→start race two operations on the same AVAudioEngine, leaking the mic or wedging it.
    private var parakeetMeterChain = Task<Void, Never> {}

    private func startParakeetMeter() {
        // Don't open the meter mic while the user is listening on AirPods: a second input
        // session knocks them out of music mode into call mode and interrupts their audio.
        // The aura simply self-breathes instead (it was already shown that way).
        guard !AudioInputDevices.defaultOutputIsBluetooth() else { return }
        parakeetMeter.onLevel = { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                self?.edgeGlow.setVoiceReactive(true)
                self?.edgeGlow.updateLevel(level)
            }
        }
        let previous = parakeetMeterChain
        parakeetMeterChain = Task { [parakeetMeter] in
            await previous.value
            // deliverChunks:false — the meter only drives the aura; it doesn't need the daemon's
            // PCM delivered anywhere (the daemon owns transcription in its own process).
            try? await parakeetMeter.start(onChunk: { _ in }, deliverChunks: false)
        }
    }

    private func stopParakeetMeter() {
        parakeetMeter.onLevel = nil
        let previous = parakeetMeterChain
        parakeetMeterChain = Task { [parakeetMeter] in
            await previous.value
            await parakeetMeter.stop()
        }
    }

    private func render(_ state: DictationState) {
        switch state {
        case .idle:
            clearDictationSession()
            endDictationActivity()
            updateIcon(recording: false)
            edgeGlow.hide()
        case .listening:
            markDictationActive()
            beginDictationActivity()
            updateIcon(recording: true)
            edgeGlow.show()
        case .finalizing:
            dictationSessionPending = false
            dictationSessionActive = true
            // Recording is over the instant the user presses stop — drop the aura and the
            // "recording" glyph right away so stop feels instant, instead of leaving the aura
            // glowing for the up-to-3s finalize safety window (the "why does it take 4-5s to
            // turn off" lag). The transcript is still being flushed/pasted in the background;
            // keep the dictation activity alive (no app-nap) until we reach `.idle`.
            updateIcon(recording: false)
            edgeGlow.hide()
        case .error(let message):
            clearDictationSession()
            endDictationActivity()
            updateIcon(recording: false)
            edgeGlow.hide()
            if message.contains("missingAPIKey") {
                promptForAPIKeyOnce()
            } else {
                presentError(Self.humanize(message))
            }
        }
    }

    /// No API key set: open Settings so the user can add one. A no-op when Settings is already
    /// open (so a repeated hotkey press doesn't stack windows), but it DOES re-open if they
    /// closed it without setting a key — otherwise every later dictation silently does nothing
    /// with no feedback (the old one-shot guard never reset and dead-ended the user).
    private func promptForAPIKeyOnce() {
        if settingsWindow?.isVisible == true { return }
        openSettings()
    }

    /// Surface a dictation failure. The aura can't show text, so genuine errors
    /// (auth, quota, network, no speech) use a standard alert — same pattern as the
    /// microphone/accessibility prompts. These are rare and need an explicit answer.
    private func presentError(_ message: String) {
        // Never a modal while quitting: runModal() inside the .terminateLater window
        // holds the reply hostage until someone clicks OK on an app that is going away.
        guard !isTerminating else {
            Diag.app.error("suppressed error alert during termination: \(message, privacy: .public)")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dictation error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func humanize(_ raw: String) -> String {
        if raw.contains("micDenied") { return "Microphone access denied" }
        if raw.contains("microphone unavailable") { return "Microphone disconnected — dictation stopped (text so far was pasted)" }
        if raw.contains("tapFailed") || raw.contains("noInput") { return "Microphone unavailable — try again" }
        if raw.contains("keychainUnavailable") { return "Can't read the API key: the Keychain refused access. Unlock the login keychain (or re-allow access for Yap) and try again." }
        if raw.contains("authenticationFailed") || raw.contains("auth_error") { return "Auth failed — check key" }
        if raw.contains("HTTP 401") || raw.contains("HTTP 403") { return "The provider rejected the API key — check it in Settings" }
        if raw.contains("HTTP 429") { return "Rate limited by the provider — wait a moment and retry" }
        if raw.contains("quotaExceeded") { return "Quota exceeded" }
        if raw.contains("rateLimited") { return "Rate limited" }
        if raw.contains("insufficient_audio_activity") { return "No speech detected" }
        if raw.contains("session_time_limit_exceeded") { return "The provider's session limit was reached — text so far was pasted" }
        if raw.contains("socketClosed") { return "Connection lost — check your internet and try again" }
        if let range = raw.range(of: "HTTP ") {
            // Pull "HTTP <code>" out of a wrapped error like `unknown("HTTP 403")` — the old
            // length guard assumed the bare string and never matched the wrapped form.
            let after = raw[range.lowerBound...].prefix { $0 != "\"" && $0 != ")" }
            return String(after).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Opt out of App Nap ONLY while dictating. A menu-bar (LSUIElement) app is
    /// aggressively napped when idle: macOS throttles its timers, thread QoS and
    /// network, which is what made the first dictation after a long idle start
    /// erratically. We hold a `.userInitiated` activity for the session and release it
    /// the moment we return to idle — so idle stays cheap while dictation runs full speed.
    private func beginDictationActivity() {
        guard dictationActivity == nil else { return }
        dictationActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Live dictation")
    }

    private func endDictationActivity() {
        guard let token = dictationActivity else { return }
        ProcessInfo.processInfo.endActivity(token)
        dictationActivity = nil
    }

    private func updateIcon(recording: Bool) {
        // Make recording visible in the menu bar too, so the app is not depending only on
        // the screen-edge aura to communicate state.
        statusItem.button?.image = recording ? Self.recordingWaveformIcon : Self.waveformIcon
        statusItem.button?.contentTintColor = nil
    }

    /// A gradient-filled `waveform` glyph (cyan → blue → violet, matching the HUD),
    /// drawn once as a non-template image so the menu bar keeps our colors.
    private static let waveformIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yap")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let size = glyph.size
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.85, blue: 0.96, alpha: 1),  // electric cyan
            NSColor(srgbRed: 0.27, green: 0.52, blue: 1.00, alpha: 1),  // electric blue
            NSColor(srgbRed: 0.61, green: 0.36, blue: 1.00, alpha: 1),  // ultraviolet
        ])?.draw(in: rect, angle: 0)
        // Clip the gradient to the glyph's shape (use the symbol's alpha as a mask).
        glyph.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1.0)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()

    private static let recordingWaveformIcon: NSImage = {
        let base = waveformIcon.copy() as? NSImage ?? waveformIcon
        let image = NSImage(size: base.size)
        image.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        let badgeSize = max(4, base.size.width * 0.22)
        let badgeRect = NSRect(
            x: base.size.width - badgeSize - 1,
            y: base.size.height - badgeSize - 1,
            width: badgeSize,
            height: badgeSize
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()

    /// Install a minimal application main menu (App + Edit). An accessory app has none by
    /// default, which is why ⌘X/⌘C/⌘V/⌘A beep inside the Settings window — those shortcuts
    /// reach the focused field only when a matching Edit-menu item is present. The menu is
    /// hidden while the app is in `.accessory`; it appears when Settings switches to
    /// `.regular`. Targets are nil so the actions route to the first responder (the field).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Yap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Yap Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        } else if let hosting = settingsWindow?.contentViewController as? NSHostingController<SettingsView>,
                  settingsWindow?.isVisible != true {
            // The window is retained across opens, so its SwiftUI @State (drafts,
            // status strings, provider picker) survives too — reopening showed the
            // previous session's half-edited state. Start every open from the
            // CURRENTLY persisted settings.
            hosting.rootView = SettingsView()
        }
        // Become a regular app while Settings is open so the window can become
        // key and accept keyboard input (accessory apps cannot be active).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
            resumeHotKey()
        }
    }

    // While the Settings window is focused, suspend the global hotkey: recording a new combo
    // (or pressing the current one) must not also toggle dictation. It's re-armed the moment
    // Settings loses focus or closes.
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { hotKey.suspend() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { resumeHotKey() }
    }

    private func resumeHotKey() {
        guard let active = activeHotKey else { return }
        // Another app can claim the combo while ours is suspended (Settings open).
        // Failing silently here left dictation with NO working hotkey and no clue why.
        if hotKey.register(active) {
            lastConflictAlerted = nil
        } else if lastConflictAlerted != active {
            lastConflictAlerted = active
            presentHotKeyConflict(active)
        }
    }

    /// Reflects whether the active provider's key is set. Recomputed each time the menu
    /// opens (menuWillOpen) so it stays accurate after the user saves a key in Settings,
    /// without any background polling.
    private func keyStatusTitle() -> String {
        let provider = AppConfig.provider
        if provider.isLocal { return "On-device engine (Parakeet)" }
        switch APIKeyStore.readAPIKey(for: provider) {
        case .found: return "API key set ✓"
        case .missing: return "No API key set"
        case .failed: return "API key unreadable (Keychain locked?)"
        }
    }

    private func dictateHintTitle() -> String {
        "Press \(AppConfig.hotKey.display) to dictate"
    }

    func menuWillOpen(_ menu: NSMenu) {
        keyStatusItem.title = keyStatusTitle()
        dictateHintItem.title = dictateHintTitle()
    }

    /// Try to make `shortcut` the active dictation hotkey. On success it's registered and
    /// persisted; on failure (the combo is already taken) the previously working shortcut is
    /// restored so dictation keeps working, and we return false so Settings can warn.
    private func applyHotKey(_ shortcut: HotKeyShortcut) -> Bool {
        // register() validates that the combo is free; on success persist it as active.
        let ok = hotKey.register(shortcut)
        if ok {
            activeHotKey = shortcut
            AppConfig.hotKey = shortcut
        }
        // We're still in Settings, so keep the hotkey suspended (it re-arms on close/blur).
        // Failure leaves the previously working shortcut as `activeHotKey` to restore then.
        if settingsWindow?.isKeyWindow == true {
            hotKey.suspend()
        } else {
            resumeHotKey()
        }
        return ok
    }

    private func presentHotKeyConflict(_ shortcut: HotKeyShortcut) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shortcut \(shortcut.display) is unavailable"
        alert.informativeText = "Another app already uses \(shortcut.display), so Yap can't start dictation with it. Open Settings and pick a different shortcut."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    /// True when dictation may start. When microphone access was denied or
    /// restricted, macOS never re-prompts on its own, so surface an alert that opens
    /// the Microphone settings instead of failing silently. `.notDetermined` flows
    /// through so the capture path shows the normal first-run system prompt.
    private func ensureMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            promptForMicrophone()
            return false
        default:
            return true
        }
    }

    /// Like `ensureMicrophoneAccess`, but resolves `.notDetermined` by actively requesting
    /// access so the grant is recorded for `com.yap`. The Parakeet path needs this because the
    /// daemon (a child process) can't surface the first-run prompt itself — Yap must own the
    /// grant up front, then the daemon inherits it.
    private func ensureMicrophoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            promptForMicrophone()
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    private func promptForMicrophone() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Microphone access is off"
        alert.informativeText = "Yap can't hear you because microphone access was denied. Open System Settings → Privacy & Security → Microphone, turn on Yap, then press \(AppConfig.hotKey.display) again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Launch at login

    private func configureLoginItem() {
        // Launch at login is opt-in via Settings only. Do not auto-register on launch.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        guard dictationSessionPending || dictationSessionActive ||
              deliveryQueue.hasPendingWork || Paster.hasPendingClipboardRestore else {
            return .terminateNow
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flushInFlightDictationIfNeeded()
            await self.deliveryQueue.cancelAndDrain()
            await Paster.waitForPendingClipboardRestore()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Shut down dictation cleanly on quit so an active session does not get cut off before the
    /// transcript reaches the delivery queue. Best-effort with timeout: if the provider stalls,
    /// quit still completes instead of hanging forever.
    private func flushInFlightDictationIfNeeded() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var stablePolls = 0

        while ContinuousClock.now < deadline {
            // Ask the active session to stop INSIDE the loop, not once up front: while a
            // session is still starting up, toggle() is debounced (no-op) — quitting in
            // that window used to wait out the whole deadline with the mic hot and the
            // dictation dropped. Retrying lands the stop the moment startup settles.
            if AppConfig.provider.isLocal {
                // Fire-and-forget (once): the local stop AWAITS its transcript poll,
                // which scales with the recording (up to 60 s on a wedged daemon) —
                // that must not hold the quit past this function's own 10 s deadline.
                if parakeetController.isRecording, !shutdownStopRequested {
                    shutdownStopRequested = true
                    Task { @MainActor [weak self] in await self?.parakeetController.toggle() }
                }
            } else if case .listening = await controller.state {
                await controller.toggle()
            }
            let cloudBusy: Bool
            if AppConfig.provider.isLocal {
                cloudBusy = parakeetController.isRecording
            } else {
                switch await controller.state {
                case .listening, .finalizing:
                    cloudBusy = true
                case .idle, .error:
                    cloudBusy = false
                }
            }
            if !dictationSessionPending && !dictationSessionActive &&
                !cloudBusy && !deliveryQueue.hasPendingWork {
                stablePolls += 1
                if stablePolls >= 3 { return }
            } else {
                stablePolls = 0
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Runs on EVERY quit path — the status-bar "Quit", the main-menu ⌘Q (which calls
    /// NSApplication.terminate directly, bypassing `quit()`), and system logout. Shut the
    /// Parakeet daemon down so it can't outlive the app holding the microphone and socket.
    func applicationWillTerminate(_ notification: Notification) {
        // Kill an in-flight setup's children (cargo build / model downloader) so they
        // don't survive Yap as orphan processes.
        ParakeetManager.shared.cancelSetup()
        parakeetController.shutdown()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)   // cleanup runs in applicationWillTerminate
    }

    private func beginDictationStartup() {
        dictationSessionPending = true
    }

    private func markDictationActive() {
        dictationSessionPending = false
        dictationSessionActive = true
    }

    private func clearDictationSession() {
        dictationSessionPending = false
        dictationSessionActive = false
    }

    enum AppError: Error { case missingAPIKey, keychainUnavailable, localEngineHasNoClient }
}
