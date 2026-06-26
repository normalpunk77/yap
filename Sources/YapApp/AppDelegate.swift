import AppKit
import AVFoundation
import ServiceManagement
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
    private var didPromptForKey = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recover keys saved under the pre-rename bundle id so they don't appear lost after
        // upgrading, then wipe any plaintext keys older builds left in UserDefaults so nothing
        // sensitive lingers in a readable plist.
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
                guard let key = APIKeyStore.loadAPIKey(for: provider), !key.isEmpty else {
                    throw AppError.missingAPIKey
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
            }
        )
        self.controller = controller

        micCapture.onLevel = { [weak self] level in
            Task { @MainActor in self?.edgeGlow.updateLevel(level) }
        }

        Task {
            await controller.setHandlers(
                onState: { state in
                    Task { @MainActor [weak self] in self?.render(state) }
                },
                onResult: { text in
                    Task { @MainActor in Paster.pasteAtCursor(text) }
                }
            )
        }

        parakeetController.onRecording = { [weak self] on in self?.renderParakeet(recording: on) }
        parakeetController.onError = { [weak self] msg in self?.presentError(msg) }

        hotKey = HotKeyManager(onTrigger: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Local engine (Parakeet) records via its daemon — a child process whose mic
                // access is attributed to Yap. So Yap itself must hold Microphone permission
                // before we start, or the daemon captures silence (and CoreAudio beeps). Only
                // gate on start; stopping needs no mic.
                if AppConfig.provider.isLocal {
                    if !self.parakeetController.isRecording {
                        guard await self.ensureMicrophoneAuthorized() else { return }
                    }
                    await self.parakeetController.toggle()
                    return
                }
                // Mic denied earlier and macOS won't re-prompt on its own: guide the
                // user to re-enable it instead of silently failing to record.
                guard self.ensureMicrophoneAccess() else { return }
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

        // Register for Accessibility on launch so Yap shows up in System Settings →
        // Privacy → Accessibility (un-toggled) the moment it's installed — the user can
        // enable it without first having to attempt a dictation. When already trusted this
        // is a silent no-op; the system dialog only appears the first time, when there is
        // no TCC entry yet. A one-shot call: no timer, no impact on idle CPU.
        Paster.promptForAccessibility()

        // A Dock-less accessory app is easy to "lose" — there's no window or Dock icon,
        // only the menu-bar glyph. Open Settings once, on the very first launch, so the
        // user can find and configure it. Afterwards it's reachable from the menu only.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            openSettings()
        }
    }

    /// Drive the aura for the local-engine path (the cloud path uses `render(_:)`).
    private func renderParakeet(recording: Bool) {
        if recording {
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
    private func startParakeetMeter() {
        parakeetMeter.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.edgeGlow.setVoiceReactive(true)
                self?.edgeGlow.updateLevel(level)
            }
        }
        Task {
            do { try await parakeetMeter.start(onChunk: { _ in }) }
            catch { /* keep the self-breathing aura; transcription (daemon) is unaffected */ }
        }
    }

    private func stopParakeetMeter() {
        parakeetMeter.onLevel = nil
        Task { await parakeetMeter.stop() }
    }

    private func render(_ state: DictationState) {
        switch state {
        case .idle:
            endDictationActivity()
            updateIcon(recording: false)
            edgeGlow.hide()
        case .listening:
            beginDictationActivity()
            updateIcon(recording: true)
            edgeGlow.show()
        case .finalizing:
            break   // keep the glow (and the activity) on until the result is delivered
        case .error(let message):
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

    /// No API key set: open Settings the FIRST time you try to dictate (helpful for a new
    /// user), then stop — so pressing the hotkey again doesn't keep popping the window. Also
    /// a no-op when Settings is already open.
    private func promptForAPIKeyOnce() {
        if settingsWindow?.isVisible == true { return }
        guard !didPromptForKey else { return }   // already prompted once — stay silent, no nagging
        didPromptForKey = true
        openSettings()
    }

    /// Surface a dictation failure. The aura can't show text, so genuine errors
    /// (auth, quota, network, no speech) use a standard alert — same pattern as the
    /// microphone/accessibility prompts. These are rare and need an explicit answer.
    private func presentError(_ message: String) {
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
        if raw.contains("tapFailed") || raw.contains("noInput") { return "Microphone unavailable — try again" }
        if raw.contains("authenticationFailed") || raw.contains("auth_error") { return "Auth failed — check key" }
        if raw.contains("quotaExceeded") { return "Quota exceeded" }
        if raw.contains("rateLimited") { return "Rate limited" }
        if raw.contains("insufficient_audio_activity") { return "No speech detected" }
        if raw.contains("socketClosed") { return "Connection closed" }
        if let range = raw.range(of: "HTTP "), raw.distance(from: range.lowerBound, to: raw.endIndex) <= 9 {
            return String(raw[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\")"))
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
        // One recognizable, colorful waveform in BOTH states — no more mic↔waveform
        // swap that made idle and active look like two different apps. Active state is
        // signalled by the edge glow / HUD, not by changing the menu-bar glyph.
        statusItem.button?.image = Self.waveformIcon
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
        if let active = activeHotKey { hotKey.register(active) }
    }

    /// Reflects whether the active provider's key is set. Recomputed each time the menu
    /// opens (menuWillOpen) so it stays accurate after the user saves a key in Settings,
    /// without any background polling.
    private func keyStatusTitle() -> String {
        let provider = AppConfig.provider
        if provider.isLocal { return "On-device engine (Parakeet)" }
        return APIKeyStore.loadAPIKey(for: provider) == nil ? "No API key set" : "API key set ✓"
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
        alert.informativeText = "Yap can't hear you because microphone access was denied. Open System Settings → Privacy & Security → Microphone, turn on Yap, then press ⌥S again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Launch at login

    private func configureLoginItem() {
        // First run after this feature ships: enable launch-at-login (the user asked
        // for it). Afterwards respect whatever they set in System Settings → Login Items.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }
    }

    @objc private func quit() {
        parakeetController.shutdown()   // stop the local engine daemon, if running
        NSApplication.shared.terminate(nil)
    }

    enum AppError: Error { case missingAPIKey, localEngineHasNoClient }
}
