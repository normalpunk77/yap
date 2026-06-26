import Foundation
import OSLog

/// Diagnostic logging to the macOS unified log. View it live with:
///
///     log stream --predicate 'subsystem == "io.github.normalpunk77.yap"' --info
///
/// or open Console.app and filter by that subsystem. It records the connection lifecycle and
/// the REAL reason a stream drops (network error, HTTP status, WebSocket close code, reconnect
/// attempts) — the detail that "Connection closed" alone hides. It NEVER logs your audio,
/// transcript text, or API key; only connection metadata, all marked `.public` so you can
/// actually read it.
public enum Diag {
    public static let conn = Logger(subsystem: "io.github.normalpunk77.yap", category: "connection")

    /// A compact, non-sensitive description of an error (domain/code/message) for logging.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code): \(ns.localizedDescription)"
    }
}
