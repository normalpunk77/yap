# Security & Privacy

Yap is a local, open-source macOS dictation app (it lives in the menu bar). It is built to be
**audited easily** — by a person, an AI coding agent, or an automated scanner. This document
states exactly what it does, what it can't do, and how to verify every claim yourself.

## Supported versions

The project is at `0.1.x`. Security fixes land on the latest version; there are no older
release lines to maintain.

## What the app does (and doesn't)

Yap captures microphone audio while you dictate, streams it to a speech-to-text
provider **you** configure, and pastes the returned transcript at your cursor. That's all.

It does **not**:

- read, log, or monitor your keystrokes;
- run a background keylogger or accessibility scraper;
- collect analytics or telemetry, or "phone home";
- create an account, sign you in, or upload anything to the author;
- auto-update or download/execute remote code;
- talk to any server other than the STT provider you chose.

## Permissions, and why each is needed

| Permission | Why | Where |
|---|---|---|
| **Microphone** | To hear your speech while dictating. Live only between the two hotkey presses. | [`MicrophoneCapture.swift`](Sources/YapApp/MicrophoneCapture.swift), declared in [`Info.plist`](Resources/Info.plist) (`NSMicrophoneUsageDescription`) and [`Yap.entitlements`](Resources/Yap.entitlements) (`device.audio-input`) |
| **Accessibility** | To paste the transcript: the app posts a single synthetic `⌘V`. | [`Paster.swift`](Sources/YapApp/Paster.swift) |
| **Launch at login** (optional) | Convenience, toggled in Settings via `SMAppService`. | [`AppDelegate.swift`](Sources/YapApp/AppDelegate.swift) |

The global hotkey (you set it in Settings) is registered with Carbon's
`RegisterEventHotKey` ([`HotKeyManager.swift`](Sources/YapApp/HotKeyManager.swift)). That API
registers **one shortcut** with the system; it is **not** an input monitor and does not require
the Input Monitoring permission. The app installs no `CGEventTap` and no `NSEvent` global monitor.

## The keystroke guarantee

Accessibility permission is powerful, so this is the most important claim to verify:
**Yap only writes output, it never reads input.** The only synthetic events it creates
are the `⌘V` key-down/up pair in `Paster.synthesizeCommandV()`, which it **posts** (output).
There is no code path that observes, intercepts, or records what you type. Verify that no
input-monitoring API is used:

```bash
grep -rniE "CGEventTapCreate|addGlobalMonitorForEvents|addLocalMonitorForEvents|IOHIDManager" Sources/
# (no matches)
```

The only `CGEvent` reference in the codebase is the paste output itself — confirm it's just
the `⌘V` being posted, nothing reading input:

```bash
grep -rn "CGEvent" Sources/   # only Paster.swift, creating/posting the ⌘V
```

The Settings shortcut recorder (`KeyRecorderView.swift`) does read keys — but **only** while
you are actively recording a new hotkey, and **only** through the responder chain on its own
field (an `NSView.keyDown`), never a global monitor. It sees nothing when you aren't setting
a shortcut, and nothing aimed at other apps.

## Data flow & network

```
mic ─▶ 16 kHz PCM16 ─▶ WebSocket to YOUR provider (YOUR key) ─▶ transcript ─▶ ⌘V paste
```

The complete list of network destinations, all hard-coded and visible in source:

| Host | Purpose | File |
|---|---|---|
| `wss://api.elevenlabs.io/v1/speech-to-text/realtime` | ElevenLabs live transcription | [`URLSessionTranscriptionSocket.swift`](Sources/YapApp/URLSessionTranscriptionSocket.swift) |
| `https://api.elevenlabs.io/v1/user` | One-shot key validity check (Save & Verify) | [`SettingsView.swift`](Sources/YapApp/SettingsView.swift) |
| `wss://api.deepgram.com/v1/listen` | Deepgram live transcription | [`URLSessionTranscriptionSocket.swift`](Sources/YapApp/URLSessionTranscriptionSocket.swift) |

Your audio is sent to the provider you selected so it can be transcribed — that is the
service you opted into. Their handling is governed by their own privacy policies
([ElevenLabs](https://elevenlabs.io/privacy), [Deepgram](https://deepgram.com/privacy)).
Nothing is sent anywhere else. Verify:

```bash
grep -rniE "https?://|wss?://" Sources/
```

## API key storage

Your provider API key is stored in `UserDefaults`
(`~/Library/Preferences/io.github.normalpunk77.yap.plist`), **not** the macOS Keychain. This is a
deliberate, documented tradeoff for a self-built, self-signed app: the Keychain ACL is keyed
to the code signature, which changes on every local rebuild and would silently lock you out
of a previously-saved key. The rationale lives next to the code in
[`APIKeyStore.swift`](Sources/YapApp/APIKeyStore.swift).

Implication: the key sits in a plaintext plist readable by processes running as your user —
the same trust boundary as most local developer tools that hold your own API key. The key
never leaves your machine except to the provider you configured. If you prefer Keychain-grade
storage, build with a stable signing identity and swap `APIKeyStore` accordingly; the type is
small and isolated for exactly this reason.

## App Sandbox

Yap is **not** App-Sandboxed, and can't be: pasting at the cursor needs Accessibility
to post a synthetic `⌘V`, the global hotkey uses a Carbon event target, and capture pins a
specific Core Audio device — all of which the sandbox forbids. This is the normal trade-off
for a system-wide dictation utility (the same category as TextExpander, Raycast, etc.). It's
mitigated by everything above: minimal entitlements (audio only), no input monitoring, no
telemetry, two known endpoints, and zero third-party code. Build it yourself and read it.

## Dependencies

Zero third-party packages. Only Apple system frameworks and a local Obj-C shim
(`Sources/ObjCExceptionCatcher`). There is no `Package.resolved` because there is nothing
external to resolve, which keeps the supply-chain surface minimal. Verify:

```bash
grep -rn "\.package(" Package.swift   # (no matches)
```

## No secrets in the repo

No API keys, tokens, or credentials are committed; keys are entered at runtime and stored
only on your machine. Verify across the full history:

```bash
grep -rniE "sk-[a-z0-9]{16}|Token [a-z0-9]{30}" $(git rev-list --all | head -50)
```

## Reporting a vulnerability

If you find a security issue, please report it privately via this repository's GitHub
**Security → Report a vulnerability** (private advisory) rather than a public issue, so it can
be fixed before disclosure. Non-sensitive bugs are welcome as normal issues.
