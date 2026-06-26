import Foundation
import YapCore

final class URLSessionTranscriptionSocket: NSObject, TranscriptionSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
        super.init()
        task.resume()
    }

    static func make(apiKey: String,
                     model: String = "scribe_v2_realtime",
                     sampleRate: Int = 16000,
                     keyterms: [String] = [],
                     noVerbatim: Bool = false) -> URLSessionTranscriptionSocket {
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [URLQueryItem(name: "model_id", value: model)]
        // VAD is the strategy ElevenLabs recommends for microphone streaming: the server
        // auto-commits transcript segments at natural silence boundaries, which the docs
        // say gives the best results. Param name + enum are from the official AsyncAPI
        // spec; we keep the documented VAD defaults (1.5 s silence / 0.4 threshold). Our
        // explicit commit on stop still flushes the tail if the user stops mid-phrase.
        items.append(URLQueryItem(name: "commit_strategy", value: "vad"))
        if noVerbatim { items.append(URLQueryItem(name: "no_verbatim", value: "true")) }
        for term in keyterms where !term.isEmpty {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: req)
        return URLSessionTranscriptionSocket(session: session, task: task)
    }

    /// Deepgram live STT. Audio is sent as raw `linear16` binary frames (our PCM16 as-is);
    /// control (Finalize/CloseStream) goes as text. Nova-3 + smart_format + interim
    /// results, with endpointing so segments finalize on natural pauses.
    static func makeDeepgram(apiKey: String,
                             model: String = "nova-3",
                             sampleRate: Int = 16000,
                             keyterms: [String] = [],
                             language: String = "multi") -> URLSessionTranscriptionSocket {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        // Without `language`, Deepgram defaults to English and garbles other languages.
        // "multi" is Nova-3 code-switching (it/en/es/fr/de/… in one utterance); Deepgram
        // recommends a tighter 100 ms endpointing for it, vs 200 ms for a single language.
        let endpointing = language == "multi" ? "100" : "200"
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: endpointing),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
        ]
        // Nova-3 keyterm prompting reuses the same custom dictionary as ElevenLabs.
        for term in keyterms where !term.isEmpty {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: req)
        return URLSessionTranscriptionSocket(session: session, task: task)
    }

    func send(_ data: Data) async throws {
        // JSON control/data goes as a text frame.
        if let json = String(data: data, encoding: .utf8) {
            try await task.send(.string(json))
        } else {
            try await task.send(.data(data))
        }
    }

    func sendBinary(_ data: Data) async throws {
        // Always a binary frame — never the UTF-8 heuristic above (silent PCM is valid
        // UTF-8 and would otherwise be misframed as a text/control message).
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        do {
            let message = try await task.receive()
            switch message {
            case .data(let d): return d
            case .string(let s): return Data(s.utf8)
            @unknown default: return Data()
            }
        } catch {
            // Surface the real handshake failure (e.g. 401 key, 400 params,
            // 403 no model access, 404 endpoint) instead of a generic close.
            if let http = task.response as? HTTPURLResponse {
                throw TranscriptionError.unknown("HTTP \(http.statusCode)")
            }
            throw TranscriptionError.unknown((error as NSError).localizedDescription)
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        // Invalidate the session too: a URLSession is not reclaimed just because its
        // task ends, so without this each dictation would leave one behind. This
        // releases it deterministically — no accumulation across many sessions.
        session.finishTasksAndInvalidate()
    }
}
