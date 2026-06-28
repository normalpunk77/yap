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

    private var daemon: Process?
    private var socketURL: URL { support.appendingPathComponent("parakeet.sock") }
    /// Pid file under Yap's control. The daemon refuses to start if its pid file already
    /// exists, so we pass an explicit path we can clean up (rather than the binary's default).
    private var pidURL: URL { support.appendingPathComponent("parakeet.pid") }
    /// The binary's *default* pid path — used to clean up daemons older builds launched
    /// without `--pid-file`, whose stale pid file would otherwise block a new start.
    private var defaultPidURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("parakeet/run/daemon.pid")
    }
    /// Where the daemon's stdout/stderr go, so a failed start (mic denied, model error) is
    /// diagnosable instead of vanishing into /dev/null. Truncated each time the daemon starts.
    var daemonLogURL: URL { support.appendingPathComponent("parakeet-daemon.log") }

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
    /// True when both the binary and a COMPLETE model are present — ready to transcribe.
    var isReady: Bool {
        binaryPath != nil && modelDownloaded
    }

    /// A model download is complete only when BOTH the small config and the large encoder
    /// weights are present. Gating on `config.json` alone declared a download interrupted after
    /// the config (but before the multi-hundred-MB encoder) as "ready" — the daemon then failed
    /// to load the model at start instead of resuming the download.
    private var modelDownloaded: Bool {
        fm.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("encoder-model.int8.onnx").path)
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

    // MARK: - Daemon (live dictation)

    /// Start the `parakeet serve` daemon (model loaded once; controlled via a Unix socket;
    /// `--clipboard` pastes each transcript to the clipboard). Idempotent. Waits for the
    /// socket to appear so the first command isn't lost. Requires `isReady`.
    func ensureDaemonRunning() async throws {
        if let daemon, daemon.isRunning { return }
        guard let bin = binaryPath else { throw ParakeetError.buildProducedNoBinary }
        // A daemon orphaned by a previous session (force-quit, crash) keeps running and leaves
        // its pid file behind; the binary then refuses to start ("PID file ... File exists").
        // Kill the orphan and clear the stale pid + socket before launching a fresh one.
        await terminateOrphanedDaemon()
        try? fm.removeItem(at: socketURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var arguments = ["serve",
                         "--model-dir", modelDir.path,
                         "--socket", socketURL.path,
                         "--pid-file", pidURL.path,
                         "--clipboard"]
        // Pin the daemon to the user's chosen input (built-in mic by default), exactly like
        // MicrophoneCapture does. Otherwise the daemon grabs the system DEFAULT input — the
        // AirPods when they're connected — which forces them out of music (A2DP) into call
        // mode (HFP), interrupting whatever the user is listening to. cpal matches by name.
        if let deviceName = preferredInputDeviceName() {
            arguments += ["--device", deviceName]
        }
        process.arguments = arguments
        // A GUI app launched by launchd inherits NO locale, so the daemon's `pbcopy` would read
        // the transcript's UTF-8 bytes as MacRoman and mangle every accent (è → √®). Force a
        // UTF-8 locale on the daemon (and the pbcopy it spawns) so accented text survives.
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "en_US.UTF-8"
        process.environment = env
        // Send the daemon's output to a log file (not /dev/null) so a failed start is
        // diagnosable. Fall back to discarding if the file can't be created.
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        fm.createFile(atPath: daemonLogURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: daemonLogURL) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        daemon = process
        // Wait up to ~30 s for the daemon to load the model and create its socket — a cold
        // start (large model off disk, first-run VAD download) can take a while. Bail out
        // immediately if the daemon exits early (e.g. a config error), so we surface the real
        // failure fast instead of waiting out the whole timeout.
        for _ in 0 ..< 600 {
            if !process.isRunning { throw ParakeetError.daemonDidNotStart }
            // Probe an actual connect(), not just that the socket FILE exists: the file appears
            // at bind() but the daemon only accepts after listen() — a `start` sent in that gap
            // can be dropped. connect() succeeds only once it's truly accepting.
            if daemonAccepting() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ParakeetError.daemonDidNotStart
    }

    /// True when a SOCK_STREAM connect to the daemon's Unix socket succeeds — i.e. it's actually
    /// accepting commands. More reliable than checking for the socket file, which exists from
    /// bind() onward (before listen()/accept()).
    private func daemonAccepting() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: pathBytes.count) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return result == 0
    }

    /// The input device name to pin the daemon to, matching the user's mic choice (built-in by
    /// default). Returns nil only when neither the chosen device nor a built-in mic resolves, in
    /// which case the daemon falls back to the system default.
    private func preferredInputDeviceName() -> String? {
        if let uid = AppConfig.preferredInputDeviceUID,
           let chosen = AudioInputDevices.all().first(where: { $0.uid == uid }) {
            return chosen.name
        }
        return AudioInputDevices.builtIn()?.name
    }

    /// Terminate a daemon left running by a previous session and remove its pid file (both the
    /// path we pass now and the binary's default, for daemons older builds started). Without
    /// this, the leftover pid file makes every new daemon refuse to start.
    private func terminateOrphanedDaemon() async {
        for pidFile in [pidURL, defaultPidURL] {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
               // macOS recycles PIDs: a stale pid file may now point at an UNRELATED process.
               // Only signal it if it's actually our parakeet binary.
               processPath(pid) == binary.path {
                kill(pid, SIGTERM)
                // Wait briefly for graceful exit, then force-kill: a daemon that ignores SIGTERM
                // would otherwise keep the mic/socket and race (or double-paste with) the fresh
                // one we're about to start. Async sleep (not usleep) so this rare orphan path
                // doesn't block the main thread.
                var alive = true
                for _ in 0 ..< 15 {
                    if kill(pid, 0) != 0 { alive = false; break }   // ESRCH → gone
                    try? await Task.sleep(nanoseconds: 10_000_000)   // 10 ms × 15 ≈ 150 ms
                }
                // Re-verify identity before the harder kill: the PID could have been recycled to
                // an unrelated process while we waited.
                if alive, processPath(pid) == binary.path { kill(pid, SIGKILL) }
            }
            try? fm.removeItem(at: pidFile)
        }
    }

    /// The executable path of the process at `pid`, or nil if it can't be read (gone, or not
    /// ours). Used to confirm a pid-file entry is really our daemon before signalling it.
    private func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Send a one-word control command (start/stop/toggle/shutdown) to the daemon socket.
    func sendDaemonCommand(_ command: String) {
        guard fm.fileExists(atPath: socketURL.path) else { return }
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", socketURL.path]
        let input = Pipe()
        nc.standardInput = input
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        guard (try? nc.run()) != nil else { return }
        input.fileHandleForWriting.write(Data("\(command)\n".utf8))
        try? input.fileHandleForWriting.close()
        // Reap the `nc` child once it exits, so repeated start/stop cycles don't pile up
        // zombie processes (its output goes to /dev/null, so it never blocks on a reader).
        DispatchQueue.global(qos: .utility).async { nc.waitUntilExit() }
    }

    func stopDaemon() {
        sendDaemonCommand("shutdown")
        daemon?.terminate()
        daemon = nil
        try? fm.removeItem(at: socketURL)
        try? fm.removeItem(at: pidURL)
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
        guard !modelDownloaded else { return }
        guard let bin = binaryPath else { throw ParakeetError.buildProducedNoBinary }
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try await runStreaming(bin, ["download", "--model-dir", modelDir.path, "--progress", "json"]) { [weak self] prog in
            self?.phase = .downloading(prog)
        }
    }

    // MARK: - Subprocess helpers

    /// Run a process to completion; throws on non-zero exit. stdout is discarded; stderr is
    /// captured so a clone/build failure (cargo/git error) is diagnosable in the log.
    private func run(_ launchPath: String, _ args: [String], cwd: URL? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        // stderr → a file (not /dev/null): cargo/git write the real failure there. A file avoids
        // the pipe-buffer deadlock a live reader could hit on a large build log.
        let errLog = support.appendingPathComponent("setup-stderr.log")
        try? fm.removeItem(at: errLog)
        fm.createFile(atPath: errLog.path, contents: nil)
        let errHandle = try? FileHandle(forWritingTo: errLog)
        process.standardError = errHandle ?? FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [errLog] proc in
                try? errHandle?.close()
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let tail = String((try? String(contentsOf: errLog, encoding: .utf8))?.suffix(2000) ?? "")
                    Diag.conn.error("\((launchPath as NSString).lastPathComponent) failed (\(proc.terminationStatus)): \(tail, privacy: .public)")
                    cont.resume(throwing: ParakeetError.commandFailed(launchPath, Int(proc.terminationStatus)))
                }
            }
            do { try process.run() } catch { try? errHandle?.close(); cont.resume(throwing: error) }
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
    case daemonDidNotStart

    var message: String {
        switch self {
        case .missingTool(let m): return m
        case .buildProducedNoBinary: return "Build finished but the parakeet binary wasn't produced."
        case .commandFailed(let path, let code):
            return "\((path as NSString).lastPathComponent) failed (exit \(code))."
        case .daemonDidNotStart: return "The local engine didn't start in time."
        }
    }
}
