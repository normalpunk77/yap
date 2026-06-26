# AI Post-Processing (Gemini) — Design

**Date:** 2026-06-26
**Status:** Approved (design), pending implementation plan
**Author:** brainstorming session

## Goal

Add an AI cleanup/formatting step that runs **immediately after STT finishes**, before the
transcript is pasted at the cursor. The first provider is **Google Gemini** (lightweight
models: 2.5 Flash Lite and 2.5 Flash), exposed with **two BYOK auth methods** — AI Studio
API key and Vertex service-account — mirroring how Friday Mac v2 wires Gemini. OpenAI will be
added later as a second LLM provider; the architecture must leave room for it without rework.

## Decisions (from brainstorming)

- **Behavior:** a single curated **default prompt** that the user can fully override in
  Settings. Overriding the prompt changes the LLM behavior entirely (not just cleanup).
- **Auth:** ship **both** API key (AI Studio) and Vertex (service-account JSON) in the same
  cycle. Vertex in pure Swift requires RS256 JWT signing + OAuth2 token exchange (no sidecar,
  unlike Friday Mac which delegates this to a TypeScript runtime).
- **Scope:** applies to **all** engines — ElevenLabs, Deepgram, and the on-device Parakeet.
  When enabled, the final text of every engine passes through Gemini. (Parakeet stays local
  for transcription; the final text leaves the device only because the user opted into AI.)
- **Models:** picker with `Gemini 2.5 Flash Lite` (default) and `Gemini 2.5 Flash`.
- **No progress indicator.** Paste when ready; no "polishing…" UI.

## Architecture

### Insertion point (blast radius)

Today both delivery paths paste directly:
- Cloud STT: `onResult` closure in `AppDelegate` (`Sources/YapApp/AppDelegate.swift:103`)
  → `Paster.pasteAtCursor(text)`.
- Local Parakeet: `ParakeetController.stop()` (`Sources/YapApp/ParakeetController.swift:62`)
  reads the clipboard → `Paster.pasteAtCursor(text)`.

Unify delivery into a single function `AppDelegate.deliver(text:)` that does
`postProcess → paste`. `ParakeetController` stops pasting itself and instead exposes an
`onText: ((String) -> Void)?` callback (parallel to its existing `onError`), which
`AppDelegate` owns. Both engines then converge on `deliver(text:)`, so post-processing is
integrated once and covers every engine.

This is the only behavioral change to existing code; STT logic is untouched.

### Components

**In `YapCore` (pure logic, testable, no AppKit):**

- `TextPostProcessor` — protocol: `func process(_ text: String) async throws -> String`.
  Provider-agnostic so OpenAI can implement it later.
- `GeminiPostProcessor: TextPostProcessor` — builds the prompt + request body, parses the
  response. Two endpoints, selected by auth method:
  - **API key (AI Studio):**
    `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={apiKey}`
  - **Vertex:**
    `POST https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/publishers/google/models/{model}:generateContent`
    with header `Authorization: Bearer {accessToken}`.
  Both use the same `generateContent` JSON shape (`systemInstruction` + `contents`), so body
  construction is shared and only URL + auth differ.
- `GoogleServiceAccountAuth` — produces a Vertex access token from a service-account JSON:
  1. Build a JWT (claims: `iss` = client_email, `scope` =
     `https://www.googleapis.com/auth/cloud-platform`, `aud` =
     `https://oauth2.googleapis.com/token`, `iat`/`exp`).
  2. Sign RS256 using the SA private key via Security framework
     (`SecKeyCreateSignature` with `.rsaSignatureMessagePKCS1v15SHA256`); the PEM private key
     from the JSON is imported with `SecKeyCreateWithData`.
  3. Exchange it at `POST https://oauth2.googleapis.com/token`
     (`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`).
  4. Cache the access token until shortly before `exp`; refresh on demand.
- `PostProcessSettings` — value struct passed into the processor:
  `enabled`, `authMethod` (`.apiKey` | `.vertex`), `model`, `prompt`,
  `vertexProject`, `vertexRegion`. Secrets are injected separately (not in this struct).

**In `YapApp`:**

- `LLMCredentialStore` — Keychain storage for LLM secrets, on **services separate** from the
  STT `APIKeyStore`: Gemini API key and the Vertex service-account JSON. Same generic-password
  pattern as `APIKeyStore`.
- `AppConfig` extension — non-secret persisted fields (UserDefaults): `postProcessEnabled`,
  `postProcessModel`, `postProcessPrompt`, `geminiAuthMethod`, `vertexProject`,
  `vertexRegion`. A never-saved-yet prompt falls back to the curated default (same pattern as
  `keyterms`: a saved empty string is respected).
- Settings UI — a new `Section("AI cleanup")` (see below).
- A shared `GeminiPostProcessor` instance built by `AppDelegate` from current config +
  credentials, rebuilt when settings change.

### Data flow

```
STT final text
   │
   ├─ postProcessEnabled == false  → paste raw
   │
   └─ enabled → GeminiPostProcessor.process(text)
                   │ success (non-empty) → paste cleaned text
                   │ error / timeout / empty → paste RAW text
```

**Invariant — never lose a dictation.** Any failure (no/invalid credential, network error,
non-200, empty candidate, Vertex token refresh failure, timeout) results in pasting the
**raw transcript**. A hard timeout (~8s) bounds how long the paste can be delayed. Failures
are logged via `Diag`; no blocking UI.

When post-processing is disabled or no credential is configured, the path is bypassed
entirely (no network call).

### Default prompt

A curated system instruction, editable in Settings with a "Reset to default" button:

> You are a transcription cleanup engine. Fix punctuation, capitalization, and obvious
> spacing. Remove filler words and false starts. Keep the speaker's exact words, meaning, and
> language unchanged — do not translate, summarize, answer, or add anything. Output only the
> cleaned text, with no preamble or quotes.

### Settings UI (new `Section("AI cleanup")`)

- `Toggle` on/off (`postProcessEnabled`).
- Segmented `Picker`: `API key (AI Studio)` / `Vertex (service account)` — same model as
  Friday Mac v2's `GeminiVertexAuthSection`.
- If **API key**: `SecureField` for the Gemini key.
- If **Vertex**: button "Choose service-account JSON…" (NSOpenPanel, `.json`); on pick, store
  JSON in Keychain and extract `project_id`; show Project (read-only) + Region (`TextField`,
  default `us-central1`).
- `Picker` model: `Gemini 2.5 Flash Lite` (default) / `Gemini 2.5 Flash`.
- `TextEditor` for the prompt + "Reset to default" button.
- "Save & Verify" — persists settings/credentials and does a lightweight validation call to
  the selected endpoint (parallel to the existing `ElevenLabsKeyCheck`), reporting a short
  status string.

### Model identifiers

- Flash Lite: `gemini-2.5-flash-lite`
- Flash: `gemini-2.5-flash`

(Confirm exact current IDs against Gemini docs during implementation.)

## Error handling

| Situation | Behavior |
|-----------|----------|
| Post-processing disabled | Bypass; paste raw, no network call |
| No / empty credential | Bypass; paste raw |
| Network error / non-200 | Log; paste raw |
| Empty or missing candidate text | Log; paste raw |
| Vertex token refresh fails | Log; paste raw |
| Exceeds ~8s timeout | Cancel; paste raw |

## Testing

Unit tests in `YapCore` using a mocked `URLProtocol` (no live network):

- Request body construction (`systemInstruction` + `contents`) is identical for both auth
  methods.
- API-key path: correct URL + `key=` query, no Authorization header.
- Vertex path: correct regional URL + `Authorization: Bearer` header.
- Response parsing: extracts the candidate text; handles empty/missing candidates.
- **Fallback-on-error → raw text** for each failure mode in the table above.
- `GoogleServiceAccountAuth`: JWT claim set is correct; RS256 signature verifies against a
  test RSA public key (generate an in-test key pair); token caching reuses a non-expired token
  and refreshes an expired one.

## Out of scope (future)

- OpenAI as a second LLM provider (architecture leaves room via `TextPostProcessor`).
- Per-style presets / multiple prompts.
- Progress indicator during processing.
- Streaming the cleaned text.

## Affected files

- New: `Sources/YapCore/TextPostProcessor.swift`, `Sources/YapCore/GeminiPostProcessor.swift`,
  `Sources/YapCore/GoogleServiceAccountAuth.swift`, `Sources/YapApp/LLMCredentialStore.swift`.
- Modified: `Sources/YapApp/AppDelegate.swift` (unified `deliver(text:)`),
  `Sources/YapApp/ParakeetController.swift` (`onText` callback, stop pasting directly),
  `Sources/YapApp/AppConfig.swift` (new fields), `Sources/YapApp/SettingsView.swift`
  (new section).
- New tests under `Tests/YapCoreTests/`.
