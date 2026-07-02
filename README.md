# Yap

[![CI](https://github.com/normalpunk77/yap/actions/workflows/ci.yml/badge.svg)](https://github.com/normalpunk77/yap/actions/workflows/ci.yml)

**Yap** is a native macOS dictation app. Press your hotkey, speak, and your words are
transcribed and pasted at the cursor — in any app. Bring your own speech-to-text API key
([ElevenLabs](https://elevenlabs.io) or [Deepgram](https://deepgram.com)), or use the
optional fully on-device engine (Parakeet) with no key at all.

It stays out of your way in the menu bar (no Dock icon; its only window is Settings) and
does **one** thing well: set your hotkey, then **press → speak → press** and the text appears
where you're typing.

> Free and open source — a genuine gift. No account, no telemetry, no tracking, no strings.
> Read every line; build it yourself. See **[Security & Privacy](#security--privacy)** and
> **[SECURITY.md](SECURITY.md)**.

---

## Features

- **Customizable global hotkey** — set it to any combo in Settings to start/stop dictation
  anywhere.
- **Three STT engines**, switchable: ElevenLabs (Scribe v2), Deepgram (Nova-3), and an
  optional fully on-device engine (Parakeet — no key, no network, built locally on opt-in).
- **Optional AI cleanup** of the transcript via Gemini (bring your own key or Vertex
  service account); on any error the raw transcript is pasted, never lost.
- **Language selection** for Deepgram (multilingual code-switching or any single language).
- **Microphone picker** — a non-Bluetooth choice is always honored; Bluetooth mics are
  avoided while you're listening on Bluetooth, so recording never knocks your AirPods out
  of music mode into low-quality call mode.
- **Custom dictionary** (keyterms) to bias recognition toward names/jargon, on both providers.
- **Launch at login**, plus in-app buttons for the Microphone and Accessibility permissions.
- Near-zero CPU when idle (no polling, no background timers).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+ or the matching Swift toolchain)
- A free/paid API key from ElevenLabs **or** Deepgram (you choose; you can use either)

## Install (one line)

Clone and install into `/Applications` — it builds locally and registers so Spotlight
finds it:

```bash
git clone https://github.com/normalpunk77/yap.git && cd yap && make install
```

Then search **Yap** in Spotlight and open it. (Because you build it yourself there's no
Gatekeeper prompt; no Apple Developer account or notarization needed.)

## Build & run

```bash
make run          # builds the .app and launches it
make install      # installs to /Applications (so Spotlight finds it) and registers it
# or, step by step:
make build        # -> build/Yap.app
make test         # runs the unit tests
```

After `make install`, search **Yap** in Spotlight. Because macOS ties permission
grants to an app's path, grant Microphone and Accessibility once for the installed copy on
first use.

Under the hood `make build` runs [`scripts/build-app.sh`](scripts/build-app.sh), which does a
plain `swift build` and packages the binary into `Yap.app`. It prefers a stable
self-signed identity named `Yap Self-Signed` if you've created one (so macOS keeps your
permission grants across rebuilds), and falls back to ad-hoc signing otherwise.

## First run

Because it's a menu-bar app, after launch look for the colorful **waveform icon** in the
menu bar (top-right) — that's Yap. Click it for **Settings** and **Quit**. On first
launch Settings opens automatically so you can configure it.

1. **Settings → Speech-to-text:** pick a provider, paste your API key, click *Save & Verify*.
2. **Permissions:** grant **Microphone** (to hear you) and **Accessibility** (to paste).
   Use the *Grant…* buttons in Settings → Permissions, or wait for the system prompts:
   the Microphone prompt appears on your first dictation, and Yap appears in
   *System Settings → Privacy & Security → Accessibility* when it first tries to paste —
   flip its switch on there.
3. Put your cursor in any text field, press your dictation hotkey, speak, and press it again.

## How it works

```
hotkey ─▶ AVCaptureSession captures your chosen mic ─▶ resample to 16 kHz PCM16
        │
        ▼
   WebSocket to your chosen provider (ElevenLabs / Deepgram) using YOUR key
   — or the local Parakeet daemon, fully on-device
        │
        ▼
   transcript ─▶ optional AI cleanup (Gemini, if YOU enabled it)
        │
        ▼
   copied to clipboard ─▶ one synthetic ⌘V pastes it at the cursor ─▶ clipboard restored
```

- `Sources/YapApp` — the macOS app: menu bar, Settings UI, mic capture, hotkey, paste.
- `Sources/YapCore` — provider-neutral transcription logic and wire models (unit-tested).
- `Sources/ObjCExceptionCatcher` — a tiny Obj-C shim so an AVFoundation `NSException` becomes
  a Swift error instead of crashing the app.

## Security & Privacy

Yap is designed to be **legibly trustworthy** — easy to audit by a human, an AI agent,
or a security scanner. The short version:

- **No telemetry, no analytics, no accounts, no auto-update, no phone-home.**
- **Every network destination is one YOU configured**, and each is reached only when its
  feature is in use:
  - STT (while dictating, plus the *Save & Verify* key check):
    `wss://api.elevenlabs.io` / `https://api.elevenlabs.io` (ElevenLabs) or
    `wss://api.deepgram.com` / `https://api.deepgram.com` (Deepgram).
  - Optional AI cleanup (only if you enable it): `generativelanguage.googleapis.com`
    (Gemini API key) or `oauth2.googleapis.com` + `{region}-aiplatform.googleapis.com`
    (Vertex service account).
  - Optional on-device engine, one-time setup (only if you click *Set up Parakeet*):
    `github.com` (clones the engine source) and Hugging Face (downloads the model).
    Dictation with Parakeet afterwards is fully offline.
  With cloud STT and no AI cleanup, your audio goes to the ONE provider you chose and
  nowhere else. There is no other recipient.
- **It does not read your keystrokes.** Accessibility permission is used *only* to paste:
  the app synthesizes a single `⌘V` ([`Paster.swift`](Sources/YapApp/Paster.swift)).
  There is **no keyboard event tap and no global key monitor** anywhere in the code. The
  hotkey (you set it in Settings) uses Carbon's `RegisterEventHotKey`
  ([`HotKeyManager.swift`](Sources/YapApp/HotKeyManager.swift)), which registers one
  shortcut — it does not observe what you type.
- **The microphone is only live during a dictation session** (between the two hotkey presses).
- **No third-party Swift dependencies** — only Apple frameworks plus the local Obj-C shim
  (no `Package.resolved`; nothing external to resolve). The optional Parakeet engine is the
  one exception you opt into explicitly: its setup clones and builds
  [`lucataco/parakeet-cli`](https://github.com/lucataco/parakeet-cli) locally and downloads
  the model — audit that repo separately if you enable it.
- **Least-privilege entitlements** — the app requests only `device.audio-input`
  ([`Resources/Yap.entitlements`](Resources/Yap.entitlements)).
- **Your credentials are stored in the macOS Keychain** (encrypted, access-controlled — see
  [`APIKeyStore.swift`](Sources/YapApp/APIKeyStore.swift)), not a plaintext file. They never
  leave your machine except to the provider you configured.
- **Diagnostic logging is local and non-sensitive.** Yap logs the connection lifecycle
  (provider, WebSocket close codes, network errors, reconnects) to the macOS unified log to
  diagnose dropped streams — never your audio, transcript, or key, and never sent anywhere
  ([`Diagnostics.swift`](Sources/YapCore/Diagnostics.swift)).

Full threat model, permission rationale, and verification commands are in **[SECURITY.md](SECURITY.md)**.

### Auditing this repo (humans & AI agents)

Don't take the claims above on faith — verify them in seconds:

```bash
# Every network host the code talks to (expect: elevenlabs.io, deepgram.com,
# googleapis.com for the optional AI cleanup, github.com/rustup.rs for the optional
# on-device engine setup):
grep -rniE "https?://|wss?://" Sources/

# Prove there's no keystroke logging (expect no matches):
grep -rniE "CGEventTapCreate|addGlobalMonitorForEvents|addLocalMonitorForEvents|IOHIDManager" Sources/
# (The only CGEvent use is POSTING the ⌘V paste — output, not input. See: grep -rn CGEvent Sources/)

# No hardcoded secrets, no ad-hoc print/NSLog (expect no matches). Diagnostic logging goes
# through os.Logger in Diagnostics.swift — connection metadata only, never audio/keys:
grep -rniE "sk-[a-z0-9]|NSLog|os_log|print\(" Sources/

# Prove there are no external dependencies (expect no matches):
grep -rn "\.package(" Package.swift
```

## License

MIT © 2026 normalpunk77. See [LICENSE](LICENSE). A gift — use it, fork it, ship it.
