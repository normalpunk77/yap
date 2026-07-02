import Foundation
import YapCore

@MainActor
final class DeliveryQueue {
    private var nextSequence = 0
    private var nextToPaste = 0
    private var running: [Int: Task<Void, Never>] = [:]
    private var ready: [Int: String] = [:]
    private var pendingRaw: [Int: String] = [:]
    private var shuttingDown = false
    private var draining = false
    private let makeProcessor: @MainActor () -> TextPostProcessor?
    private let paste: @MainActor (String) async -> Void

    init(makeProcessor: @escaping @MainActor () -> TextPostProcessor?,
         paste: @escaping @MainActor (String) async -> Void) {
        self.makeProcessor = makeProcessor
        self.paste = paste
    }

    var hasPendingWork: Bool { !running.isEmpty || !ready.isEmpty || draining }

    func enqueue(_ text: String) {
        guard !shuttingDown else { return }
        let sequence = nextSequence
        nextSequence += 1
        pendingRaw[sequence] = text
        let processor = makeProcessor()
        let task = Task { [weak self, processor] in
            let finalText = await PostProcessRunner.run(text, with: processor)
            await MainActor.run { self?.finish(sequence: sequence, text: finalText) }
        }
        running[sequence] = task
    }

    func cancelAndDrain() async {
        shuttingDown = true
        let tasks = Array(running.values)
        tasks.forEach { $0.cancel() }
        // Let an in-flight drain finish its current paste first, so the shutdown drain
        // can't write the NEXT transcript to the pasteboard while the previous ⌘V is
        // still being consumed by the target app.
        while draining {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await drainForShutdown()
    }

    private func finish(sequence: Int, text: String) {
        running[sequence] = nil
        guard !shuttingDown else { return }
        ready[sequence] = text
        drainReady()
    }

    /// Deliver ready transcripts strictly one at a time, awaiting each paste's settle
    /// window. The old synchronous loop burst-pasted back-to-back: the second clipboard
    /// write landed before the target app consumed the first ⌘V, so the earlier
    /// dictation was never pasted and the later text went in twice.
    private func drainReady() {
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard !self.shuttingDown, let text = self.ready[self.nextToPaste] else { break }
                self.ready[self.nextToPaste] = nil
                self.pendingRaw[self.nextToPaste] = nil
                self.nextToPaste += 1
                await self.paste(text)
            }
            self?.draining = false
        }
    }

    private func drainForShutdown() async {
        while nextToPaste < nextSequence {
            if let text = ready[nextToPaste] ?? pendingRaw[nextToPaste] {
                ready[nextToPaste] = nil
                pendingRaw[nextToPaste] = nil
                nextToPaste += 1
                await paste(text)
                continue
            }
            break
        }
        running.removeAll()
        ready.removeAll()
        pendingRaw.removeAll()
    }
}
