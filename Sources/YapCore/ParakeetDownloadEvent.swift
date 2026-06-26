import Foundation

/// One newline-delimited JSON event emitted by `parakeet download --progress json`.
/// Schema (captured from the tool): a `start`, then per file `fileStart` → many
/// `fileProgress` → `fileComplete`, then a final `complete`.
public struct ParakeetDownloadEvent: Decodable, Equatable, Sendable {
    public let type: String
    public let file: String?
    public let index: Int?         // 0-based file index
    public let total: Int?         // bytes in the current file
    public let downloaded: Int?    // bytes downloaded so far in the current file
    public let totalFiles: Int?

    /// Parse one NDJSON line; nil if it isn't a valid event (e.g. a blank/log line).
    public static func parse(_ line: String) -> ParakeetDownloadEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParakeetDownloadEvent.self, from: data)
    }
}

/// A UI-ready snapshot of overall model-download progress.
public struct ParakeetDownloadProgress: Equatable, Sendable {
    public let file: String
    public let fileIndex: Int      // 0-based
    public let totalFiles: Int
    public let fileFraction: Double // 0...1 within the current file

    public init(file: String, fileIndex: Int, totalFiles: Int, fileFraction: Double) {
        self.file = file
        self.fileIndex = fileIndex
        self.totalFiles = totalFiles
        self.fileFraction = fileFraction
    }

    /// Map a download event to a progress snapshot, or nil for non-progress events.
    public static func from(_ event: ParakeetDownloadEvent) -> ParakeetDownloadProgress? {
        switch event.type {
        case "fileStart", "fileProgress", "fileComplete":
            let total = event.total ?? 0
            let fraction = total > 0 ? min(1, Double(event.downloaded ?? 0) / Double(total)) : 0
            return ParakeetDownloadProgress(
                file: event.file ?? "",
                fileIndex: event.index ?? 0,
                totalFiles: event.totalFiles ?? 1,
                fileFraction: fraction)
        default:
            return nil
        }
    }

    /// "file 2 of 4 · 37%" — a compact human label for the UI.
    public var label: String {
        "file \(fileIndex + 1) of \(totalFiles) · \(Int(fileFraction * 100))%"
    }
}
