import Foundation
import SwiftUI
import YapCore

/// Sets up and owns the local Parakeet engine: builds the `parakeet-cli` binary on the user's
/// machine (cargo), downloads the model with live progress, and tracks readiness. Everything
/// lives under `~/Library/Application Support/Yap`. UI observes `phase`.
@MainActor
final class ParakeetManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checkingTools
        case cloning
        case building
        case downloading(ParakeetDownloadProgress)
        case ready
        case failed(String)
    }

    static let shared = ParakeetManager()
    @Published private(set) var phase: Phase = .idle

    private let fm = FileManager.default
    private var support: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yap", isDirectory: true)
    }
    private var repoDir: URL { support.appendingPathComponent("parakeet-cli", isDirectory: true) }
    private var binary: URL { repoDir.appendingPathComponent("target/release/parakeet") }
    private var modelDir: URL { support.appendingPathComponent("models/parakeet-tdt-0.6b-v3", isDirectory: true) }

    private static let repoURL = "https://github.com/lucataco/parakeet-cli.git"

    /// The built binary's path, or nil if it isn't built yet.
    var binaryPath: String? { fm.isExecutableFile(atPath: binary.path) ? binary.path : nil }
    var modelDirPath: String { modelDir.path }
    /// True when both the binary and the model are present — ready to transcribe.
    var isReady: Bool {
        binaryPath != nil && fm.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
    }

    /// Build (if needed) and download (if needed) so the engine is ready. Idempotent: returns
    /// immediately when already set up. Runs the heavy steps as child processes, surfacing the
    /// real download progress.
    func ensureReady() async {
        if isReady { phase = .ready; return }
        do {
            try await buildBinaryIfNeeded()
            try await downloadModelIfNeeded()
            phase = .ready
        } catch {
            let msg = (error as? ParakeetError)?.message ?? (error as NSError).localizedDescription
            phase = .failed(msg)
            Diag.conn.error("Parakeet setup failed: \(msg, privacy: .public)")
        }
    }

    // MARK: - Build

    private func buildBinaryIfNeeded() async throws {
        guard binaryPath == nil else { return }
        phase = .checkingTools
        guard let cargo = Self.locate(["\(NSHomeDirectory())/.cargo/bin/cargo",
                                       "/opt/homebrew/bin/cargo", "/usr/local/bin/cargo"]) else {
            throw ParakeetError.missingTool(
                "Rust toolchain (cargo) not found. Install it from https://rustup.rs, then retry.")
        }
        let git = Self.locate(["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]) ?? "/usr/bin/git"
        try fm.createDirectory(at: support, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
            phase = .cloning
            try? fm.removeItem(at: repoDir)   // clear any partial clone
            try await run(git, ["clone", "--depth", "1", Self.repoURL, repoDir.path])
        }
        phase = .building
        try await run(cargo, ["build", "--release", "--bin", "parakeet"], cwd: repoDir)
        guard binaryPath != nil else { throw ParakeetError.buildProducedNoBinary }
    }

    // MARK: - Download

    private func downloadModelIfNeeded() async throws {
        guard !fm.fileExists(atPath: modelDir.appendingPathComponent("config.json").path) else { return }
        guard let bin = binaryPath else { throw ParakeetError.buildProducedNoBinary }
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try await runStreaming(bin, ["download", "--model-dir", modelDir.path, "--progress", "json"]) { [weak self] prog in
            self?.phase = .downloading(prog)
        }
    }

    // MARK: - Subprocess helpers

    /// Run a process to completion; throws on non-zero exit. stdout/stderr are discarded.
    private func run(_ launchPath: String, _ args: [String], cwd: URL? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: ParakeetError.commandFailed(launchPath, Int(proc.terminationStatus)))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Run a process, parsing each stdout line as a download progress event and forwarding
    /// snapshots to `onProgress`. Throws on non-zero exit.
    private func runStreaming(_ launchPath: String, _ args: [String],
                              onProgress: @escaping @MainActor (ParakeetDownloadProgress) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if let event = ParakeetDownloadEvent.parse(line),
               let progress = ParakeetDownloadProgress.from(event) {
                onProgress(progress)
            }
        }
        process.waitUntilExit()   // stdout hit EOF → the process has finished
        guard process.terminationStatus == 0 else {
            throw ParakeetError.commandFailed(launchPath, Int(process.terminationStatus))
        }
    }

    private static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum ParakeetError: Error {
    case missingTool(String)
    case buildProducedNoBinary
    case commandFailed(String, Int)

    var message: String {
        switch self {
        case .missingTool(let m): return m
        case .buildProducedNoBinary: return "Build finished but the parakeet binary wasn't produced."
        case .commandFailed(let path, let code):
            return "\((path as NSString).lastPathComponent) failed (exit \(code))."
        }
    }
}
