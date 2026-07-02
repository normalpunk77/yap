import Foundation
import SwiftUI
import YapCore
import Darwin

/// Sets up and owns the local Parakeet engine: builds the `parakeet-cli` binary on the user's
/// machine (cargo), downloads the model with live progress, and tracks readiness. Everything
/// lives under `~/Library/Application Support/Yap`. UI observes `phase`.
@MainActor
final class ParakeetManager: ObservableObject, ParakeetManaging {
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
    private var setupTask: Task<Void, Never>?

    func ensureReady() async {
        if isReady { phase = .ready; return }
        // Coalesce concurrent setups: a second tap (e.g. a Retry double-click) while a build or
        // download is already in flight must NOT spawn a second cargo build / downloader writing
        // the same files. Both callers await the one in-flight task.
        if let setupTask { return await setupTask.value }
        let task = Task { await runSetup() }
        setupTask = task
        defer { setupTask = nil }
        await task.value
    }

    /// Cancel an in-flight setup, terminating its child processes (cargo build / model
    /// downloader). Called on app quit — without it those children survive as orphans,
    /// burning CPU and writing files long after Yap is gone.
    func cancelSetup() {
        setupTask?.cancel()
    }

    private func runSetup() async {
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
        // Send the daemon's DIAGNOSTICS (stderr) to a log file so a failed start is
        // diagnosable. stdout is discarded on purpose: the daemon prints every finished
        // TRANSCRIPT there, and logging it persisted the user's dictated text in
        // plaintext on disk. The log is created user-only (0600) — Application Support
        // files default to world-readable.
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        fm.createFile(atPath: daemonLogURL.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        process.standardOutput = FileHandle.nullDevice
        if let logHandle = try? FileHandle(forWritingTo: daemonLogURL) {
            process.standardError = logHandle
        } else {
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
    /// bind() onward (before listen()/accept()). Reuses the same connect helper as command sends.
    private func daemonAccepting() -> Bool {
        guard let fd = connectUnixSocket(path: socketURL.path) else { return false }
        close(fd)
        return true
    }

    /// The input device name to pin the daemon to, resolved through the SAME policy as
    /// `MicrophoneCapture` (honor a non-Bluetooth selection; avoid Bluetooth inputs while
    /// output is Bluetooth; built-in → non-Bluetooth fallback). The old built-in-only
    /// fallback returned nil on Macs without a built-in mic, letting the daemon grab the
    /// system DEFAULT input — the very AirPods the policy exists to avoid.
    private func preferredInputDeviceName() -> String? {
        guard let uid = AudioInputDevices.preferredDictationInputUID() else { return nil }
        return AudioInputDevices.all().first(where: { $0.uid == uid })?.name
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
    func sendDaemonCommand(_ command: String) -> Bool {
        guard fm.fileExists(atPath: socketURL.path) else { return false }
        guard let fd = connectUnixSocket(path: socketURL.path) else { return false }
        defer { close(fd) }
        let data = Data("\(command)\n".utf8)
        var writtenAll = false
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let remaining = rawBuffer.count - written
                let result = write(fd, base.advanced(by: written), remaining)
                if result > 0 {
                    written += result
                    continue
                }
                if result == -1, errno == EINTR { continue }
                return
            }
            writtenAll = true
        }
        return writtenAll
    }

    /// Connect a SOCK_STREAM Unix socket to `path`, returning the fd (caller closes it) or nil.
    /// SO_NOSIGPIPE so a write to a vanished daemon fails with EPIPE instead of killing the app.
    private func connectUnixSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                         &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0 else {
            close(fd)
            return nil
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8CString.count <= pathCapacity else {
            close(fd)
            return nil
        }

        let connected = path.withCString { cString -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { pathBytes in
                guard let base = pathBytes.bindMemory(to: CChar.self).baseAddress else { return }
                memset(base, 0, pathBytes.count)
                _ = strncpy(base, cString, pathBytes.count - 1)
            }
            return withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    while true {
                        if connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 {
                            return true
                        }
                        if errno == EINTR { continue }
                        return false
                    }
                }
            }
        }

        guard connected else {
            close(fd)
            return nil
        }
        return fd
    }

    func stopDaemon() {
        _ = sendDaemonCommand("shutdown")
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
        // Terminate the child if the enclosing task is cancelled (app quit, setup
        // abandoned) — a clone/build otherwise keeps running as an orphan.
        try await withTaskCancellationHandler {
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
        } onCancel: {
            process.terminate()
        }
    }

    /// Run a process, parsing each stdout line as a download progress event and forwarding
    /// snapshots to `onProgress`. Throws on non-zero exit.
    private func runStreaming(_ launchPath: String, _ args: [String],
                              onProgress: @escaping @MainActor (ParakeetDownloadProgress) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let decoder = JSONDecoder()
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr → a file (like run()) so a download failure (network/404/TLS) is diagnosable.
        let errLog = support.appendingPathComponent("setup-stderr.log")
        try? fm.removeItem(at: errLog)
        fm.createFile(atPath: errLog.path, contents: nil)
        let errHandle = try? FileHandle(forWritingTo: errLog)
        process.standardError = errHandle ?? FileHandle.nullDevice
        try process.run()
        // If the enclosing Task is cancelled (user leaves setup mid-download), terminate the child
        // so it stops writing the model files — otherwise a later retry races a second downloader
        // writing the same paths.
        try await withTaskCancellationHandler {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if let event = ParakeetDownloadEvent.parse(line, decoder: decoder),
                   let progress = ParakeetDownloadProgress.from(event) {
                    onProgress(progress)
                }
            }
            process.waitUntilExit()   // stdout hit EOF → the process has finished
            try? errHandle?.close()
            guard process.terminationStatus == 0 else {
                let tail = String((try? String(contentsOf: errLog, encoding: .utf8))?.suffix(2000) ?? "")
                Diag.conn.error("\((launchPath as NSString).lastPathComponent) download failed (\(process.terminationStatus)): \(tail, privacy: .public)")
                throw ParakeetError.commandFailed(launchPath, Int(process.terminationStatus))
            }
        } onCancel: {
            // Cancellation skips the normal-path close above — close the pipe read end and the
            // log handle here too, or each cancelled download leaks file descriptors.
            process.terminate()
            try? errHandle?.close()
            try? pipe.fileHandleForReading.close()
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
