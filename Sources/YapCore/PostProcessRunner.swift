import Foundation

/// Runs a post-processor while GUARANTEEING the dictation is never lost: on any failure
/// (nil processor, throw, timeout, empty output) the raw transcript is returned unchanged.
public enum PostProcessRunner {
    public static func run(
        _ raw: String,
        with processor: TextPostProcessor?,
        timeout: Duration = .seconds(8)
    ) async -> String {
        if Task.isCancelled { return raw }
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
            if Task.isCancelled { return raw }
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
