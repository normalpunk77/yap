# AI Post-Processing (Gemini) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a user-configurable Gemini cleanup pass on the final transcript (all engines) before it is pasted, with API-key and Vertex service-account auth.

**Architecture:** Pure post-processing logic lives in `YapCore` (a `TextPostProcessor` protocol + a `GeminiPostProcessor`, plus a `PostProcessRunner` that guarantees the never-lose-text invariant). `YapApp` stores credentials in Keychain, persists non-secret settings in `AppConfig`, builds the processor, and routes both delivery paths through one `deliver(text:)` function.

**Tech Stack:** Swift 6, macOS 14, SwiftUI Settings, `URLSession` (REST), Security framework (`SecKey` RS256 signing), Keychain (generic-password). Tests: XCTest with a custom `URLProtocol` mock. No third-party dependencies.

## Global Constraints

- `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]` — no new SwiftPM dependencies (verbatim from `Package.swift`).
- All `YapCore` types crossing concurrency boundaries must be `Sendable` (Swift 6 strict concurrency).
- **Never lose a dictation:** any post-processing failure (disabled, no/invalid credential, network error, non-200, empty candidate, token-refresh failure, timeout ≈8s) results in pasting the **raw transcript**.
- Diagnostics must NOT log transcript text, prompts, API keys, or the SA JSON — only metadata, marked `.public` (mirrors `Sources/YapCore/Diagnostics.swift`).
- Keychain services for LLM secrets are **separate** from the STT `APIKeyStore` services.
- Test target is `YapCoreTests` only (no `YapApp` test target exists). `YapApp`-only tasks are verified with `swift build`; mark unit-test step N/A with that reason.
- Gemini model IDs: `gemini-2.5-flash-lite` (default), `gemini-2.5-flash`.
- Gemini REST shape (both auth methods share the body):
  - API key: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={apiKey}`
  - Vertex: `POST https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/publishers/google/models/{model}:generateContent` + header `Authorization: Bearer {token}`
  - Body: `{"systemInstruction":{"parts":[{"text":<prompt>}]},"contents":[{"role":"user","parts":[{"text":<transcript>}]}],"generationConfig":{"temperature":0}}`
  - Response: `{"candidates":[{"content":{"parts":[{"text":<output>}]}}]}`

---

### Task 1: Post-processing settings types + default prompt

**Files:**
- Create: `Sources/YapCore/PostProcessSettings.swift`
- Test: `Tests/YapCoreTests/PostProcessSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum GeminiAuthMethod: String, CaseIterable, Sendable { case apiKey, vertex }`
  - `public enum GeminiModel: String, CaseIterable, Sendable { case flashLite = "gemini-2.5-flash-lite"; case flash = "gemini-2.5-flash"; public var displayName: String }`
  - `public struct PostProcessSettings: Sendable, Equatable { public var enabled: Bool; public var authMethod: GeminiAuthMethod; public var model: GeminiModel; public var prompt: String; public var vertexProject: String; public var vertexRegion: String; public init(...) }`
  - `public enum PostProcessDefaults { public static let prompt: String; public static let vertexRegion = "us-central1" }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import YapCore

final class PostProcessSettingsTests: XCTestCase {
    func testModelRawValuesAreGeminiIDs() {
        XCTAssertEqual(GeminiModel.flashLite.rawValue, "gemini-2.5-flash-lite")
        XCTAssertEqual(GeminiModel.flash.rawValue, "gemini-2.5-flash")
    }

    func testDefaultPromptIsNonEmptyAndCleanupOriented() {
        let p = PostProcessDefaults.prompt.lowercased()
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(p.contains("only"))   // "output only the cleaned text"
    }

    func testDefaultRegion() {
        XCTAssertEqual(PostProcessDefaults.vertexRegion, "us-central1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PostProcessSettingsTests`
Expected: FAIL — `cannot find 'GeminiModel' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PostProcessSettingsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/YapCore/PostProcessSettings.swift Tests/YapCoreTests/PostProcessSettingsTests.swift
git commit -m "feat(postproc): Gemini settings types and default prompt"
```

---

### Task 2: Gemini wire model (request body + response parse)

**Files:**
- Create: `Sources/YapCore/GeminiWireModel.swift`
- Test: `Tests/YapCoreTests/GeminiWireModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum GeminiWire { public static func requestBody(prompt: String, transcript: String) throws -> Data; public static func parseText(_ data: Data) throws -> String }`
  - `public enum GeminiWireError: Error, Equatable { case noCandidateText }`
- `requestBody` returns JSON matching the shape in Global Constraints. `parseText` returns the first candidate's concatenated part texts; throws `.noCandidateText` if absent/empty.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import YapCore

final class GeminiWireModelTests: XCTestCase {
    func testRequestBodyShape() throws {
        let data = try GeminiWire.requestBody(prompt: "SYS", transcript: "hello world")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sys = obj["systemInstruction"] as! [String: Any]
        let sysParts = sys["parts"] as! [[String: Any]]
        XCTAssertEqual(sysParts.first?["text"] as? String, "SYS")
        let contents = obj["contents"] as! [[String: Any]]
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        let userParts = contents.first?["parts"] as! [[String: Any]]
        XCTAssertEqual(userParts.first?["text"] as? String, "hello world")
        let gen = obj["generationConfig"] as! [String: Any]
        XCTAssertEqual(gen["temperature"] as? Double, 0)
    }

    func testParseTextExtractsCandidate() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hello, world."}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiWire.parseText(json), "Hello, world.")
    }

    func testParseTextConcatenatesMultipleParts() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hello, "},{"text":"world."}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiWire.parseText(json), "Hello, world.")
    }

    func testParseTextThrowsOnNoCandidates() {
        let json = #"{"candidates":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiWire.parseText(json)) { error in
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }

    func testParseTextThrowsOnBlockedEmpty() {
        let json = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiWire.parseText(json)) { error in
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GeminiWireModelTests`
Expected: FAIL — `cannot find 'GeminiWire' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum GeminiWireError: Error, Equatable {
    case noCandidateText
}

/// Builds the `generateContent` request body and parses its response. The body is identical
/// for the API-key and Vertex endpoints — only the URL and auth header differ (see
/// GeminiPostProcessor).
public enum GeminiWire {
    public static func requestBody(prompt: String, transcript: String) throws -> Data {
        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": prompt]]],
            "contents": [["role": "user", "parts": [["text": transcript]]]],
            "generationConfig": ["temperature": 0],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func parseText(_ data: Data) throws -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw GeminiWireError.noCandidateText }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiWireError.noCandidateText }
        return trimmed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GeminiWireModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/YapCore/GeminiWireModel.swift Tests/YapCoreTests/GeminiWireModelTests.swift
git commit -m "feat(postproc): Gemini request body + response parsing"
```

---

### Task 3: GeminiPostProcessor — API-key path (injectable URLSession)

**Files:**
- Create: `Sources/YapCore/TextPostProcessor.swift`
- Create: `Sources/YapCore/GeminiPostProcessor.swift`
- Test: `Tests/YapCoreTests/GeminiPostProcessorTests.swift`
- Test helper: `Tests/YapCoreTests/MockURLProtocol.swift`

**Interfaces:**
- Consumes: `GeminiWire` (Task 2), `PostProcessSettings`/`GeminiModel` (Task 1).
- Produces:
  - `public protocol TextPostProcessor: Sendable { func process(_ text: String) async throws -> String }`
  - `public struct GeminiPostProcessor: TextPostProcessor` with
    `public init(model: GeminiModel, prompt: String, auth: GeminiPostProcessor.Auth, session: URLSession = .shared)`
  - `public enum GeminiPostProcessor.Auth: Sendable { case apiKey(String); case vertex(token: () async throws -> String, project: String, region: String) }`
  - `public enum GeminiPostProcessorError: Error, Equatable { case httpStatus(Int); case emptyResponse }`
- This task implements only the `.apiKey` case end-to-end. `.vertex` is added in Task 6 (define the enum case now but it may `fatalError`/throw a placeholder until Task 6 — instead, leave it `throw GeminiPostProcessorError.emptyResponse` is wrong; define it but route to a `notImplemented`? No — define the case and implement its URL now without the token call). Implement `.vertex` URL building now but call the token closure; Task 6 supplies the real `GoogleServiceAccountAuth`. Both cases are wired here; Task 6 only adds the token *source*.

- [ ] **Step 1: Write the failing test (and the mock protocol)**

`Tests/YapCoreTests/MockURLProtocol.swift`:

```swift
import Foundation

/// Intercepts URLSession requests in tests so no real network call is made. Set
/// `handler` to inspect the outgoing request and return the canned (status, body) or throw.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            // URLProtocol strips httpBody for some methods; expose it via httpBodyStream too.
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                req.httpBody = Data(reading: stream)
            }
            let (status, body) = try handler(req)
            let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private extension Data {
    init(reading input: InputStream) {
        self.init()
        input.open()
        defer { input.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: size)
            if read <= 0 { break }
            append(buffer, count: read)
        }
    }
}
```

`Tests/YapCoreTests/GeminiPostProcessorTests.swift`:

```swift
import XCTest
@testable import YapCore

final class GeminiPostProcessorTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    func testApiKeyPathHitsCorrectURLAndReturnsCleanText() async throws {
        var seenURL: URL?
        var seenAuthHeader: String?
        MockURLProtocol.handler = { req in
            seenURL = req.url
            seenAuthHeader = req.value(forHTTPHeaderField: "Authorization")
            let body = #"{"candidates":[{"content":{"parts":[{"text":"Hello, world."}]}}]}"#.data(using: .utf8)!
            return (200, body)
        }
        let proc = GeminiPostProcessor(
            model: .flashLite,
            prompt: "SYS",
            auth: .apiKey("SECRET"),
            session: MockURLProtocol.session()
        )
        let out = try await proc.process("hello world")
        XCTAssertEqual(out, "Hello, world.")
        XCTAssertEqual(seenURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=SECRET")
        XCTAssertNil(seenAuthHeader)   // API-key path uses the query param, not a Bearer header
    }

    func testNon200Throws() async {
        MockURLProtocol.handler = { _ in (401, Data("nope".utf8)) }
        let proc = GeminiPostProcessor(model: .flash, prompt: "SYS", auth: .apiKey("BAD"),
                                       session: MockURLProtocol.session())
        do {
            _ = try await proc.process("hi")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? GeminiPostProcessorError, .httpStatus(401))
        }
    }

    func testEmptyCandidateThrows() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"candidates":[]}"#.utf8)) }
        let proc = GeminiPostProcessor(model: .flash, prompt: "SYS", auth: .apiKey("K"),
                                       session: MockURLProtocol.session())
        do {
            _ = try await proc.process("hi")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? GeminiWireError, .noCandidateText)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GeminiPostProcessorTests`
Expected: FAIL — `cannot find 'GeminiPostProcessor' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/YapCore/TextPostProcessor.swift`:

```swift
import Foundation

/// Cleans/formats a finished transcript before it is pasted. Provider-agnostic so other
/// backends (e.g. OpenAI) can be added later without touching callers.
public protocol TextPostProcessor: Sendable {
    func process(_ text: String) async throws -> String
}
```

`Sources/YapCore/GeminiPostProcessor.swift`:

```swift
import Foundation

public enum GeminiPostProcessorError: Error, Equatable {
    case httpStatus(Int)
    case emptyResponse
}

/// Calls Gemini's `generateContent` to clean a transcript. Two auth styles share the request
/// body (GeminiWire) and differ only in URL + auth header.
public struct GeminiPostProcessor: TextPostProcessor {
    /// `vertex.token` is an async closure that yields a fresh OAuth access token (Task 6 wires
    /// GoogleServiceAccountAuth here). Kept as a closure so this type stays free of Keychain.
    public enum Auth: Sendable {
        case apiKey(String)
        case vertex(token: @Sendable () async throws -> String, project: String, region: String)
    }

    private let model: GeminiModel
    private let prompt: String
    private let auth: Auth
    private let session: URLSession

    public init(model: GeminiModel, prompt: String, auth: Auth, session: URLSession = .shared) {
        self.model = model
        self.prompt = prompt
        self.auth = auth
        self.session = session
    }

    public func process(_ text: String) async throws -> String {
        let request = try await makeRequest(transcript: text)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw GeminiPostProcessorError.httpStatus(code) }
        return try GeminiWire.parseText(data)
    }

    private func makeRequest(transcript: String) async throws -> URLRequest {
        let body = try GeminiWire.requestBody(prompt: prompt, transcript: transcript)
        switch auth {
        case .apiKey(let key):
            let url = URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent?key=\(key)")!
            return jsonPOST(url, body: body)
        case .vertex(let token, let project, let region):
            let url = URL(string:
                "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model.rawValue):generateContent")!
            var req = jsonPOST(url, body: body)
            let accessToken = try await token()
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return req
        }
    }

    private func jsonPOST(_ url: URL, body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GeminiPostProcessorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/YapCore/TextPostProcessor.swift Sources/YapCore/GeminiPostProcessor.swift Tests/YapCoreTests/GeminiPostProcessorTests.swift Tests/YapCoreTests/MockURLProtocol.swift
git commit -m "feat(postproc): GeminiPostProcessor API-key path with mocked URLSession"
```

---

### Task 4: PostProcessRunner — never-lose-text invariant (fallback + timeout)

**Files:**
- Create: `Sources/YapCore/PostProcessRunner.swift`
- Test: `Tests/YapCoreTests/PostProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `TextPostProcessor` (Task 3).
- Produces:
  - `public enum PostProcessRunner { public static func run(_ raw: String, with processor: TextPostProcessor?, timeout: Duration = .seconds(8)) async -> String }`
- Guarantees: returns the processor's cleaned output on success; returns `raw` unchanged if `processor` is nil, throws, times out, or returns whitespace-only. Logs failures via `Diag` without the text.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import YapCore

private struct StubProcessor: TextPostProcessor {
    let behavior: @Sendable (String) async throws -> String
    func process(_ text: String) async throws -> String { try await behavior(text) }
}

private struct StubError: Error {}

final class PostProcessRunnerTests: XCTestCase {
    func testNilProcessorReturnsRaw() async {
        let out = await PostProcessRunner.run("raw text", with: nil)
        XCTAssertEqual(out, "raw text")
    }

    func testSuccessReturnsCleaned() async {
        let proc = StubProcessor { _ in "cleaned" }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "cleaned")
    }

    func testThrowFallsBackToRaw() async {
        let proc = StubProcessor { _ in throw StubError() }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "raw")
    }

    func testEmptyResultFallsBackToRaw() async {
        let proc = StubProcessor { _ in "   \n " }
        let out = await PostProcessRunner.run("raw", with: proc)
        XCTAssertEqual(out, "raw")
    }

    func testTimeoutFallsBackToRaw() async {
        let proc = StubProcessor { _ in
            try await Task.sleep(for: .seconds(10))
            return "too late"
        }
        let out = await PostProcessRunner.run("raw", with: proc, timeout: .milliseconds(50))
        XCTAssertEqual(out, "raw")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PostProcessRunnerTests`
Expected: FAIL — `cannot find 'PostProcessRunner' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Runs a post-processor while GUARANTEEING the dictation is never lost: on any failure
/// (nil processor, throw, timeout, empty output) the raw transcript is returned unchanged.
public enum PostProcessRunner {
    public static func run(
        _ raw: String,
        with processor: TextPostProcessor?,
        timeout: Duration = .seconds(8)
    ) async -> String {
        guard let processor else { return raw }
        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group -> String in
                group.addTask { try await processor.process(raw) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Diag.conn.error("postproc returned empty → pasting raw transcript")
                return raw
            }
            return trimmed
        } catch {
            Diag.conn.error("postproc failed → pasting raw transcript: \(Diag.describe(error), privacy: .public)")
            return raw
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PostProcessRunnerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/YapCore/PostProcessRunner.swift Tests/YapCoreTests/PostProcessRunnerTests.swift
git commit -m "feat(postproc): PostProcessRunner guarantees raw-text fallback + timeout"
```

---

### Task 5: GoogleServiceAccountAuth — RS256 JWT + OAuth token

**Files:**
- Create: `Sources/YapCore/GoogleServiceAccountAuth.swift`
- Test: `Tests/YapCoreTests/GoogleServiceAccountAuthTests.swift`

**Interfaces:**
- Consumes: `MockURLProtocol` (Task 3), `GeminiWire` not needed.
- Produces:
  - `public struct ServiceAccount: Sendable, Equatable { public let clientEmail: String; public let privateKeyPEM: String; public let projectID: String; public init?(json: String) }`
  - `public actor GoogleServiceAccountAuth { public init(account: ServiceAccount, session: URLSession = .shared, now: @Sendable () -> Date = Date.init); public func accessToken() async throws -> String }`
  - `public enum GoogleAuthError: Error, Equatable { case badPrivateKey; case signingFailed; case tokenStatus(Int); case noAccessToken }`
  - Internal-but-`@testable`-visible: `func makeJWT() throws -> String` and `static func signRS256(_ signingInput: String, pemPKCS8: String) throws -> String` so the signature can be unit-verified.
- `ServiceAccount(json:)` parses `client_email`, `private_key`, `project_id`; returns nil if any is missing.
- `accessToken()` returns a cached token until ~60s before expiry, otherwise mints a new JWT, exchanges it at `https://oauth2.googleapis.com/token`, caches `access_token`+`expires_in`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Security
@testable import YapCore

final class GoogleServiceAccountAuthTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    /// Generates a throwaway RSA key pair and returns (pkcs8 PEM private key, SecKey public key).
    private func makeTestKey() throws -> (pem: String, publicKey: SecKey) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let pub = SecKeyCopyPublicKey(priv)!
        // Export the private key (PKCS#1 DER) and wrap it into a PKCS#8 PEM, matching what a
        // Google SA JSON contains.
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &error)! as Data
        let pem = GoogleServiceAccountAuth.pkcs8PEM(fromPKCS1DER: pkcs1)
        return (pem, pub)
    }

    func testServiceAccountParsesJSON() {
        let json = #"{"client_email":"a@b.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n","project_id":"my-proj"}"#
        let sa = ServiceAccount(json: json)
        XCTAssertEqual(sa?.clientEmail, "a@b.iam.gserviceaccount.com")
        XCTAssertEqual(sa?.projectID, "my-proj")
    }

    func testServiceAccountRejectsMissingFields() {
        XCTAssertNil(ServiceAccount(json: #"{"client_email":"x"}"#))
    }

    func testRS256SignatureVerifies() throws {
        let (pem, publicKey) = try makeTestKey()
        let signingInput = "header.payload"
        let jwsSig = try GoogleServiceAccountAuth.signRS256(signingInput, pemPKCS8: pem)
        // Recover raw signature bytes from base64url and verify against the public key.
        let raw = Data(base64urlEncoded: jwsSig)!
        let ok = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                       Data(signingInput.utf8) as CFData, raw as CFData, nil)
        XCTAssertTrue(ok)
    }

    func testAccessTokenExchangeAndCache() async throws {
        let (pem, _) = try makeTestKey()
        let sa = ServiceAccount(json: """
        {"client_email":"a@b.iam.gserviceaccount.com","private_key":\(pemJSONEscaped(pem)),"project_id":"p"}
        """)!
        var calls = 0
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
            calls += 1
            return (200, Data(#"{"access_token":"TOKEN123","expires_in":3600}"#.utf8))
        }
        let auth = GoogleServiceAccountAuth(account: sa, session: MockURLProtocol.session())
        let t1 = try await auth.accessToken()
        let t2 = try await auth.accessToken()   // cached: no second network call
        XCTAssertEqual(t1, "TOKEN123")
        XCTAssertEqual(t2, "TOKEN123")
        XCTAssertEqual(calls, 1)
    }

    private func pemJSONEscaped(_ pem: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [pem])
        let arr = String(data: data, encoding: .utf8)!   // ["...\n..."]
        return String(arr.dropFirst().dropLast())        // strip [ ]
    }
}
```

Add a small base64url helper used by tests and impl, in the impl file (see Step 3).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GoogleServiceAccountAuthTests`
Expected: FAIL — `cannot find 'ServiceAccount' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Security

public enum GoogleAuthError: Error, Equatable {
    case badPrivateKey
    case signingFailed
    case tokenStatus(Int)
    case noAccessToken
}

/// The fields we need from a Google service-account JSON key file.
public struct ServiceAccount: Sendable, Equatable {
    public let clientEmail: String
    public let privateKeyPEM: String
    public let projectID: String

    public init?(json: String) {
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = obj["client_email"] as? String, !email.isEmpty,
            let key = obj["private_key"] as? String, !key.isEmpty,
            let project = obj["project_id"] as? String, !project.isEmpty
        else { return nil }
        self.clientEmail = email
        self.privateKeyPEM = key
        self.projectID = project
    }
}

/// Mints and caches a Vertex OAuth access token from a service-account key, entirely in Swift
/// (no sidecar). JWT is RS256-signed with the SA private key via the Security framework.
public actor GoogleServiceAccountAuth {
    private let account: ServiceAccount
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cachedToken: String?
    private var expiry: Date = .distantPast

    public init(account: ServiceAccount,
                session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.account = account
        self.session = session
        self.now = now
    }

    public func accessToken() async throws -> String {
        if let cachedToken, now() < expiry.addingTimeInterval(-60) { return cachedToken }
        let jwt = try makeJWT()
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        req.httpBody = form.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw GoogleAuthError.tokenStatus(code) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = obj["access_token"] as? String
        else { throw GoogleAuthError.noAccessToken }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        cachedToken = token
        expiry = now().addingTimeInterval(ttl)
        return token
    }

    func makeJWT() throws -> String {
        let iat = Int(now().timeIntervalSince1970)
        let exp = iat + 3600
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": iat,
            "exp": exp,
        ]
        let h = try JSONSerialization.data(withJSONObject: header).base64urlEncodedString()
        let c = try JSONSerialization.data(withJSONObject: claims).base64urlEncodedString()
        let signingInput = "\(h).\(c)"
        let sig = try Self.signRS256(signingInput, pemPKCS8: account.privateKeyPEM)
        return "\(signingInput).\(sig)"
    }

    /// Sign `signingInput` with RS256 using a PKCS#8 PEM private key (the format in SA JSON).
    static func signRS256(_ signingInput: String, pemPKCS8: String) throws -> String {
        let der = try pkcs1DER(fromPEM: pemPKCS8)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw GoogleAuthError.badPrivateKey
        }
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData, &error
        ) else {
            throw GoogleAuthError.signingFailed
        }
        return (signature as Data).base64urlEncodedString()
    }

    /// Strip PEM armor + the fixed 26-byte PKCS#8 RSA wrapper to get the PKCS#1 RSAPrivateKey
    /// DER that SecKeyCreateWithData expects. (SA keys are unencrypted PKCS#8.)
    static func pkcs1DER(fromPEM pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "\n")   // JSON-escaped newlines
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let pkcs8 = Data(base64Encoded: base64) else { throw GoogleAuthError.badPrivateKey }
        let prefixLen = 26
        guard pkcs8.count > prefixLen else { throw GoogleAuthError.badPrivateKey }
        return pkcs8.subdata(in: prefixLen ..< pkcs8.count)
    }

    /// Inverse of pkcs1DER: wrap a PKCS#1 DER into a PKCS#8 PEM (test helper).
    static func pkcs8PEM(fromPKCS1DER pkcs1: Data) -> String {
        let header: [UInt8] = [
            0x30, 0x82, 0x00, 0x00, 0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a,
            0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, 0x82,
            0x00, 0x00,
        ]
        var inner = header
        // length of the inner OCTET STRING (pkcs1)
        inner[24] = UInt8((pkcs1.count >> 8) & 0xff)
        inner[25] = UInt8(pkcs1.count & 0xff)
        var body = Data(inner) ; body.append(pkcs1)
        // outer SEQUENCE length
        let total = body.count - 4
        body[2] = UInt8((total >> 8) & 0xff)
        body[3] = UInt8(total & 0xff)
        let b64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(b64)\n-----END PRIVATE KEY-----\n"
    }
}

extension Data {
    func base64urlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
```

> **Note for implementer:** if `testRS256SignatureVerifies` fails on the PKCS#8 prefix length, the SA key may use a different wrapper. Verify by round-tripping `pkcs1DER(fromPEM: pkcs8PEM(fromPKCS1DER: x)) == x` in the test; the 26-byte prefix is correct for standard 2048-bit Google SA keys.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GoogleServiceAccountAuthTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/YapCore/GoogleServiceAccountAuth.swift Tests/YapCoreTests/GoogleServiceAccountAuthTests.swift
git commit -m "feat(postproc): Google service-account RS256 JWT + OAuth token minting"
```

---

### Task 6: Wire Vertex path end-to-end in GeminiPostProcessor

**Files:**
- Modify: `Tests/YapCoreTests/GeminiPostProcessorTests.swift`

**Interfaces:**
- Consumes: `GeminiPostProcessor.Auth.vertex` (Task 3), `GoogleServiceAccountAuth` (Task 5).
- Produces: no new types — proves the `.vertex` case builds the regional URL and Bearer header. (The `.vertex` URL/header code already exists from Task 3; this task adds its test coverage now that a token source exists.)

- [ ] **Step 1: Write the failing test (append to GeminiPostProcessorTests)**

```swift
    func testVertexPathHitsRegionalURLWithBearer() async throws {
        var seenURL: URL?
        var seenAuth: String?
        MockURLProtocol.handler = { req in
            seenURL = req.url
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            let body = #"{"candidates":[{"content":{"parts":[{"text":"Ciao."}]}}]}"#.data(using: .utf8)!
            return (200, body)
        }
        let proc = GeminiPostProcessor(
            model: .flash,
            prompt: "SYS",
            auth: .vertex(token: { "TOK" }, project: "my-proj", region: "europe-west1"),
            session: MockURLProtocol.session()
        )
        let out = try await proc.process("ciao")
        XCTAssertEqual(out, "Ciao.")
        XCTAssertEqual(seenURL?.absoluteString,
            "https://europe-west1-aiplatform.googleapis.com/v1/projects/my-proj/locations/europe-west1/publishers/google/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(seenAuth, "Bearer TOK")
    }

    func testVertexTokenFailurePropagates() async {
        struct Boom: Error {}
        MockURLProtocol.handler = { _ in (200, Data(#"{"candidates":[]}"#.utf8)) }
        let proc = GeminiPostProcessor(
            model: .flash, prompt: "S",
            auth: .vertex(token: { throw Boom() }, project: "p", region: "us-central1"),
            session: MockURLProtocol.session()
        )
        do { _ = try await proc.process("x"); XCTFail("expected throw") }
        catch { XCTAssertTrue(error is Boom) }
    }
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `swift test --filter GeminiPostProcessorTests`
Expected: PASS — the `.vertex` implementation from Task 3 already satisfies these. If `testVertexTokenFailurePropagates` fails, ensure the token closure is awaited **before** the network call in `makeRequest` (it is).

- [ ] **Step 3: (No implementation change expected)**

If both new tests pass, skip. If the URL differs, fix the `.vertex` URL string in `GeminiPostProcessor.makeRequest` to match the assertion exactly.

- [ ] **Step 4: Run the full YapCore suite**

Run: `swift test`
Expected: PASS (all post-processing tests green).

- [ ] **Step 5: Commit**

```bash
git add Tests/YapCoreTests/GeminiPostProcessorTests.swift
git commit -m "test(postproc): cover Gemini Vertex path URL + Bearer auth"
```

---

### Task 7: LLMCredentialStore (Keychain)

**Files:**
- Create: `Sources/YapApp/LLMCredentialStore.swift`

**Interfaces:**
- Consumes: nothing (mirrors `Sources/YapApp/APIKeyStore.swift`).
- Produces:
  - `enum LLMCredentialStore` with:
    - `static func saveGeminiAPIKey(_ value: String)` / `static func loadGeminiAPIKey() -> String?`
    - `static func saveVertexServiceAccountJSON(_ value: String)` / `static func loadVertexServiceAccountJSON() -> String?`
  - Keychain services: `com.yap.gemini-api-key` and `com.yap.gemini-vertex-sa`, account `api-key` (matching `APIKeyStore`'s account constant style). An empty value clears the item.

- [ ] **Step 1: Write the implementation** (no YapApp test target — verified by build + the Save & Verify flow in Task 10)

```swift
import Foundation
import Security

/// Keychain storage for LLM (post-processing) secrets, on services SEPARATE from the STT
/// APIKeyStore: the Gemini AI-Studio API key and the Vertex service-account JSON. Same
/// generic-password pattern as APIKeyStore (encrypted at rest, not readable via `defaults`).
enum LLMCredentialStore {
    private static let account = "api-key"
    private static let geminiKeyService = "com.yap.gemini-api-key"
    private static let vertexSAService = "com.yap.gemini-vertex-sa"

    static func saveGeminiAPIKey(_ value: String) { save(value, service: geminiKeyService) }
    static func loadGeminiAPIKey() -> String? { load(service: geminiKeyService) }
    static func saveVertexServiceAccountJSON(_ value: String) { save(value, service: vertexSAService) }
    static func loadVertexServiceAccountJSON() -> String? { load(service: vertexSAService) }

    private static func save(_ value: String, service: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // empty = cleared
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/YapApp/LLMCredentialStore.swift
git commit -m "feat(postproc): Keychain store for Gemini key + Vertex SA JSON"
```

---

### Task 8: AppConfig — persisted post-processing settings

**Files:**
- Modify: `Sources/YapApp/AppConfig.swift`

**Interfaces:**
- Consumes: `GeminiAuthMethod`, `GeminiModel`, `PostProcessSettings`, `PostProcessDefaults` (Task 1); `LLMCredentialStore` (Task 7).
- Produces, on `AppConfig`:
  - `static var postProcessEnabled: Bool` (default false)
  - `static var geminiAuthMethod: GeminiAuthMethod` (default `.apiKey`)
  - `static var postProcessModel: GeminiModel` (default `.flashLite`)
  - `static var postProcessPrompt: String` (get/set; falls back to `PostProcessDefaults.prompt` when never saved, like keyterms)
  - `static var vertexProject: String` (default "")
  - `static var vertexRegion: String` (default `PostProcessDefaults.vertexRegion`)
  - `static func postProcessSettings() -> PostProcessSettings` assembling the above.

- [ ] **Step 1: Add the fields** (append inside `enum AppConfig`, before the closing brace; add keys to the private key list at the top)

Add to the key constants block near the top of the enum:

```swift
    private static let postProcEnabledKey = "postproc_enabled"
    private static let postProcModelKey = "postproc_model"
    private static let postProcPromptKey = "postproc_prompt"
    private static let geminiAuthMethodKey = "gemini_auth_method"
    private static let vertexProjectKey = "vertex_project"
    private static let vertexRegionKey = "vertex_region"
```

Add the accessors (anywhere inside the enum):

```swift
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
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/YapApp/AppConfig.swift
git commit -m "feat(postproc): persist Gemini post-processing settings in AppConfig"
```

---

### Task 9: Unified delivery + wiring (both engines through the processor)

**Files:**
- Modify: `Sources/YapApp/ParakeetController.swift`
- Modify: `Sources/YapApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `PostProcessRunner` (Task 4), `GeminiPostProcessor` (Task 3/6), `GoogleServiceAccountAuth`/`ServiceAccount` (Task 5), `AppConfig.postProcessSettings()` (Task 8), `LLMCredentialStore` (Task 7).
- Produces:
  - `ParakeetController.onText: ((String) -> Void)?` — replaces its direct paste.
  - `AppDelegate.deliver(text:)` — the single delivery path (`postProcess → paste`).
  - `AppDelegate.makePostProcessor() -> TextPostProcessor?` — builds the processor from current settings + credentials, or nil when disabled/unconfigured.

- [ ] **Step 1: ParakeetController stops pasting; emits text**

In `Sources/YapApp/ParakeetController.swift`, add the callback near `onError`:

```swift
    /// The finished transcript, for the owner to post-process + paste. Replaces the old
    /// direct paste so the local engine shares the cloud delivery path.
    var onText: ((String) -> Void)?
```

Replace the paste in `stop()` (currently `if !text.isEmpty { Paster.pasteAtCursor(text) }`) with:

```swift
                if !text.isEmpty { onText?(text) }
```

Remove the now-unused `import` only if `Paster` is no longer referenced in the file (it isn't elsewhere) — leave `import AppKit` (still used for `NSPasteboard`).

- [ ] **Step 2: AppDelegate — add the unified delivery + processor builder**

Add these methods to `AppDelegate` (e.g. after `applicationDidFinishLaunching`):

```swift
    /// THE single delivery path for every engine: run the optional AI cleanup (which always
    /// falls back to the raw transcript on any failure), then paste at the cursor.
    private func deliver(text: String) {
        Task { @MainActor in
            let processor = self.makePostProcessor()
            let finalText = await PostProcessRunner.run(text, with: processor)
            Paster.pasteAtCursor(finalText)
        }
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
            let auth = GoogleServiceAccountAuth(account: account)
            let region = s.vertexRegion.isEmpty ? PostProcessDefaults.vertexRegion : s.vertexRegion
            return GeminiPostProcessor(
                model: s.model, prompt: s.prompt,
                auth: .vertex(token: { try await auth.accessToken() },
                              project: s.vertexProject, region: region)
            )
        }
    }
```

- [ ] **Step 3: Route both engines through `deliver`**

Cloud path — change the `onResult` closure (currently pastes directly at `AppDelegate.swift:103`):

```swift
                onResult: { text in
                    Task { @MainActor [weak self] in self?.deliver(text: text) }
                }
```

Local path — where `parakeetController` callbacks are wired (near `parakeetController.onError = …`), add:

```swift
        parakeetController.onText = { [weak self] text in self?.deliver(text: text) }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: Build succeeds with no warnings about unused `Paster` import.

- [ ] **Step 5: Commit**

```bash
git add Sources/YapApp/ParakeetController.swift Sources/YapApp/AppDelegate.swift
git commit -m "feat(postproc): route all engines through unified deliver(text:) with Gemini cleanup"
```

---

### Task 10: Settings UI — AI cleanup section + Save & Verify

**Files:**
- Modify: `Sources/YapApp/SettingsView.swift`

**Interfaces:**
- Consumes: `AppConfig` post-processing accessors (Task 8), `LLMCredentialStore` (Task 7), `GeminiModel`/`GeminiAuthMethod`/`PostProcessDefaults` (Task 1), `ServiceAccount` (Task 5), `GeminiPostProcessor` (Task 3).
- Produces: a new `Section("AI cleanup")` in the form, plus a `GeminiKeyCheck` enum (parallel to `ElevenLabsKeyCheck`) for Save & Verify.

- [ ] **Step 1: Add state properties** (with the other `@State` vars at the top of `SettingsView`)

```swift
    // AI post-processing (Gemini)
    @State private var ppEnabled: Bool = AppConfig.postProcessEnabled
    @State private var ppAuth: GeminiAuthMethod = AppConfig.geminiAuthMethod
    @State private var ppModel: GeminiModel = AppConfig.postProcessModel
    @State private var ppPrompt: String = AppConfig.postProcessPrompt
    @State private var geminiKey: String = LLMCredentialStore.loadGeminiAPIKey() ?? ""
    @State private var vertexProject: String = AppConfig.vertexProject
    @State private var vertexRegion: String = AppConfig.vertexRegion
    @State private var ppStatus: String = ""
```

- [ ] **Step 2: Add the section** (insert in `body`'s `Form`, after the "Custom dictionary (keyterms)" section)

```swift
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
                                    .onSubmit { AppConfig.vertexRegion = vertexRegion }
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
```

- [ ] **Step 3: Add the actions + verifier** (add methods to `SettingsView`, and a `GeminiKeyCheck` enum near `ElevenLabsKeyCheck`)

```swift
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
        AppConfig.vertexRegion = vertexRegion
        if ppAuth == .apiKey { LLMCredentialStore.saveGeminiAPIKey(geminiKey) }
        ppStatus = "Verifying…"
        let settings = AppConfig.postProcessSettings()
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await GeminiKeyCheck.check(settings: settings, apiKey: key)
            await MainActor.run { ppStatus = result }
        }
    }
```

Add near `ElevenLabsKeyCheck` (end of file):

```swift
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
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Manual smoke test**

Run: `make run` (or `swift run YapApp`). In Settings → AI cleanup: toggle on, enter a Gemini API key, Save & Verify → expect "✓ Working — saved". Dictate a messy sentence → the pasted text is cleaned. Toggle off → raw text pastes. Disconnect network with it on → raw text still pastes (fallback).

- [ ] **Step 6: Commit**

```bash
git add Sources/YapApp/SettingsView.swift
git commit -m "feat(postproc): Settings UI for Gemini cleanup (auth, model, prompt, verify)"
```

---

## Self-Review

**Spec coverage:**
- Insertion point / unified delivery → Task 9. ✓
- All engines (incl. Parakeet) → Task 9 (`ParakeetController.onText`). ✓
- Gemini API-key path → Task 3. ✓
- Vertex SA (RS256 JWT + OAuth) → Tasks 5, 6. ✓
- Never-lose-text invariant (fallback + timeout) → Task 4. ✓
- Curated, overridable default prompt → Tasks 1, 8, 10 (Reset). ✓
- Model picker, Flash Lite default → Tasks 1, 8, 10. ✓
- Keychain credential storage (separate services) → Task 7. ✓
- Settings UI + Save & Verify → Task 10. ✓
- Tests with URLProtocol mock → Tasks 3, 5, 6. ✓
- OpenAI left room via `TextPostProcessor` protocol → Task 3. ✓

**Type consistency:** `TextPostProcessor.process` signature, `GeminiPostProcessor.Auth` cases, `PostProcessSettings` fields, `GeminiModel` raw values, and `AppConfig.postProcessSettings()` are referenced identically across Tasks 1–10.

**No progress indicator** (per user) — confirmed: `deliver(text:)` pastes when ready, no UI state.
