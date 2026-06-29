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
    private let makeProcessor: @MainActor () -> TextPostProcessor?
    private let paste: @MainActor (String) -> Void

    init(makeProcessor: @escaping @MainActor () -> TextPostProcessor?,
         paste: @escaping @MainActor (String) -> Void) {
        self.makeProcessor = makeProcessor
        self.paste = paste
    }

    var hasPendingWork: Bool { !running.isEmpty || !ready.isEmpty }

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
        drainForShutdown()
    }

    private func finish(sequence: Int, text: String) {
        running[sequence] = nil
        guard !shuttingDown else { return }
        ready[sequence] = text
        drainReady()
    }

    private func drainReady() {
        while let text = ready[nextToPaste] {
            ready[nextToPaste] = nil
            pendingRaw[nextToPaste] = nil
            nextToPaste += 1
            paste(text)
        }
    }

    private func drainForShutdown() {
        while nextToPaste < nextSequence {
            if let text = ready[nextToPaste] ?? pendingRaw[nextToPaste] {
                ready[nextToPaste] = nil
                pendingRaw[nextToPaste] = nil
                nextToPaste += 1
                paste(text)
                continue
            }
            break
        }
        running.removeAll()
        ready.removeAll()
        pendingRaw.removeAll()
    }
}
