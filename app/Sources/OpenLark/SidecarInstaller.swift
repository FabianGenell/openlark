import Darwin
import Foundation

/// One-shot installer for the Python inference daemon.
///
/// Downloads a pre-built runtime tarball (Python + parakeet-mlx + mlx + numpy)
/// from the openlark GitHub releases, extracts it into
/// ~/Library/Application Support/OpenLark/runtime/, copies the bundled
/// server.py into ~/Library/Application Support/OpenLark/sidecar/, writes the
/// launchd plist, and loads it.
///
/// One HTTPS GET + `tar -xzf` instead of "download Python, create venv, pip
/// install many wheels". Much faster (3-4×), much more reliable (no pip
/// resolve, no transient PyPI errors).
@MainActor
final class SidecarInstaller: ObservableObject {
    static let shared = SidecarInstaller()

    enum Stage: Equatable {
        case idle
        case checking
        case alreadyInstalled
        case downloading(progress: Double)
        case extracting
        case registeringDaemon
        case waitingForSocket
        case downloadingModel(progress: Double)
        case done
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Ready"
            case .checking: return "Checking…"
            case .alreadyInstalled: return "Speech engine already installed"
            case .downloading(let p): return "Downloading speech engine: \(Int(p * 100))%"
            case .extracting: return "Extracting…"
            case .registeringDaemon: return "Registering background daemon…"
            case .waitingForSocket: return "Starting daemon…"
            case .downloadingModel(let p):
                return p < 0 ? "Downloading speech model…" : "Downloading speech model - \(Int(p * 100))%"
            case .done: return "Speech engine ready"
            case .failed(let m): return "Failed: \(m)"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .done, .alreadyInstalled, .failed: return true
            default: return false
            }
        }

        var isError: Bool {
            if case .failed = self { return true } else { return false }
        }

        var caseKey: String {
            switch self {
            case .idle: return "idle"
            case .checking: return "checking"
            case .alreadyInstalled: return "alreadyInstalled"
            case .downloading: return "downloading"
            case .extracting: return "extracting"
            case .registeringDaemon: return "registeringDaemon"
            case .waitingForSocket: return "waitingForSocket"
            case .downloadingModel: return "downloadingModel"
            case .done: return "done"
            case .failed: return "failed"
            }
        }
    }

    @Published var stage: Stage = .idle {
        didSet {
            if stage.caseKey != oldValue.caseKey {
                AppLogger.log("installer stage: \(stage.description)")
            }
        }
    }

    /// Prebuilt runtime bundle. Bump the URL when the wheel set changes
    /// (parakeet-mlx version bump, Python bump, etc.). Each new bundle gets
    /// its own runtime-vN release so updates are explicit.
    private let runtimeBundleURL = URL(string:
        "https://github.com/FabianGenell/openlark/releases/download/runtime-v2/openlark-runtime-arm64-darwin.tar.gz"
    )!

    var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLark", isDirectory: true)
    }
    var runtimeRoot: URL { supportRoot.appendingPathComponent("runtime", isDirectory: true) }
    var sidecarRoot: URL { supportRoot.appendingPathComponent("sidecar", isDirectory: true) }
    var runtimePython: URL { runtimeRoot.appendingPathComponent("python/bin/python3") }
    var serverScript: URL { sidecarRoot.appendingPathComponent("server.py") }

    var logsRoot: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OpenLark", isDirectory: true)
    }
    var launchAgentURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("app.openlark.sidecar.plist")
    }

    /// Marker file recording the wire-protocol version of the currently-
    /// installed sidecar. Bump `currentInstalledVersion` whenever server.py
    /// changes in a way that breaks the running daemon (new env vars,
    /// new wire protocol, new pip deps). On launch we compare; mismatch
    /// triggers an in-place reinstall (daemon unload + new plist + load).
    var installedVersionURL: URL {
        supportRoot.appendingPathComponent(".installed-version", isDirectory: false)
    }
    /// v3 = multi-model JSON-header protocol + mlx-whisper dep
    ///      (HF_HOME was tried in v2; reverted to default to keep existing caches).
    /// v4 = hang-hardened daemon: socket binds before model load, startup
    ///      watchdog, fail-fast on missing model, prefetch heartbeats. Bumped so
    ///      existing installs get the new server.py + restart on next launch.
    private let currentInstalledVersion = "4"

    private var isRunning = false
    private var installTask: Task<Void, Never>?

    /// True if a daemon is already serving on the socket. Doesn't care which
    /// installer put it there. A bare file-exists check would falsely report
    /// healthy when the daemon crashed and left a stale socket. We probe
    /// with a real connect.
    func isDaemonHealthy() -> Bool {
        guard FileManager.default.fileExists(atPath: "/tmp/openlark.sock") else {
            return false
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array("/tmp/openlark.sock".utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(b) }
                dst[pathBytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return true
        }
        // Stale socket, daemon dead. Unlink so launchctl load can re-bind cleanly.
        try? FileManager.default.removeItem(atPath: "/tmp/openlark.sock")
        return false
    }

    func ensureRunning() {
        guard !isRunning, !stage.isTerminal || stage.isError else { return }
        installTask = Task { await install() }
    }

    /// User-triggered abort from the onboarding UI. Cancels the in-flight
    /// install; install() catches CancellationError and moves to .failed, which
    /// surfaces the Retry button so the user is never trapped on a stalled step.
    func cancelInstall() {
        installTask?.cancel()
    }

    func install() async {
        if isRunning { return }
        isRunning = true
        defer { isRunning = false }
        stage = .checking

        let configIsCurrent = installedVersionMatches()

        if isDaemonHealthy() && configIsCurrent {
            stage = .alreadyInstalled
            return
        }

        do {
            try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
            try copyServerScript()

            if !FileManager.default.fileExists(atPath: runtimePython.path) {
                try await downloadAndExtractRuntime()
            }
            try Task.checkCancellation()

            // Always tear down any old daemon when the installed version is
            // stale. An old server.py can't talk the new wire protocol.
            if !configIsCurrent {
                AppLogger.log("config version stale, restarting sidecar")
                _ = try? await runProcess(
                    executable: "/bin/launchctl",
                    arguments: ["unload", launchAgentURL.path],
                    timeout: 20
                )
                try? FileManager.default.removeItem(atPath: "/tmp/openlark.sock")
            }

            stage = .registeringDaemon
            try writeLaunchAgent()
            try await loadLaunchAgent()

            stage = .waitingForSocket
            try await waitForDaemon()

            // The engine is not truly ready until the active speech model is
            // downloaded. Do it here with visible progress and bounded timeouts
            // rather than letting the first dictation trigger a silent,
            // unbounded multi-minute download that looks like a hang.
            try await prefetchActiveModel()

            writeInstalledVersion()
            stage = .done
        } catch is CancellationError {
            stage = .failed("Setup cancelled - press Retry to try again.")
        } catch {
            AppLogger.log("installer failed: \(error)")
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private func installedVersionMatches() -> Bool {
        guard let data = try? Data(contentsOf: installedVersionURL),
              let s = String(data: data, encoding: .utf8) else {
            return false
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == currentInstalledVersion
    }

    private func writeInstalledVersion() {
        try? FileManager.default.createDirectory(
            at: supportRoot, withIntermediateDirectories: true
        )
        try? currentInstalledVersion.write(
            to: installedVersionURL, atomically: true, encoding: .utf8
        )
    }

    private func copyServerScript() throws {
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.url(forResource: "server", withExtension: "py", subdirectory: "sidecar") else {
            throw NSError(
                domain: "OpenLark.installer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled server.py missing, corrupt .app bundle?"]
            )
        }
        try? FileManager.default.removeItem(at: serverScript)
        try FileManager.default.copyItem(at: bundled, to: serverScript)
    }

    private func downloadAndExtractRuntime() async throws {
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let tarPath = runtimeRoot.appendingPathComponent("runtime.tar.gz")

        try await downloadFile(from: runtimeBundleURL, to: tarPath) { progress in
            self.stage = .downloading(progress: progress)
        }

        stage = .extracting
        try await runProcess(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", tarPath.path, "-C", runtimeRoot.path]
        )
        try? FileManager.default.removeItem(at: tarPath)

        guard FileManager.default.fileExists(atPath: runtimePython.path) else {
            throw NSError(
                domain: "OpenLark.installer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "runtime layout unexpected: \(runtimePython.path) missing after extract"]
            )
        }
    }

    private func writeLaunchAgent() throws {
        let plist: [String: Any] = [
            "Label": "app.openlark.sidecar",
            "ProgramArguments": [runtimePython.path, serverScript.path],
            "WorkingDirectory": sidecarRoot.path,
            "EnvironmentVariables": [
                "OPENLARK_SOCKET": "/tmp/openlark.sock",
                "PYTHONUNBUFFERED": "1",
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            // Models are cached at the HuggingFace default ~/.cache/huggingface
            // so existing downloads (from before multi-model support) are
            // detected and not re-downloaded.
            "RunAtLoad": true,
            "KeepAlive": true,
            // Cap respawn rate so a daemon that crashes on startup logs at a
            // sane cadence instead of spinning. The app separately detects a
            // dead engine via the ping in waitForDaemon() and surfaces Retry.
            "ThrottleInterval": 10,
            "StandardOutPath": logsRoot.appendingPathComponent("sidecar.log").path,
            "StandardErrorPath": logsRoot.appendingPathComponent("sidecar.log").path,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: launchAgentURL)
    }

    private func loadLaunchAgent() async throws {
        // Unload any prior version of the agent. Older installs from the
        // shell-script path or previous installer versions may still be
        // registered. Runs off the main thread (via runProcess) with a bounded
        // timeout so a wedged launchctl can't freeze the UI or the install.
        _ = try? await runProcess(
            executable: "/bin/launchctl",
            arguments: ["unload", launchAgentURL.path],
            timeout: 20
        )
        try await runProcess(
            executable: "/bin/launchctl",
            arguments: ["load", launchAgentURL.path],
            timeout: 20
        )
    }

    private func waitForDaemon() async throws {
        // Verify the daemon is actually SERVING with a real ping round-trip, not
        // just that the socket file exists. A socket that exists but never
        // answers (crash loop, wedged startup) used to be reported as "ready",
        // stranding the user with a dead engine and no error. If no ping
        // succeeds within the deadline we throw, so stage becomes .failed and
        // the Retry button appears. The daemon now binds its socket before any
        // model work, so a healthy daemon answers within a second or two.
        let client = SidecarClient()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            if await client.ping() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(
            domain: "OpenLark.installer", code: 3,
            userInfo: [NSLocalizedDescriptionKey:
                "Speech engine didn't start. Check ~/Library/Logs/OpenLark/sidecar.log, then press Retry."]
        )
    }

    private func prefetchActiveModel() async throws {
        let client = SidecarClient()
        let modelId = UserModelSettings.activeModelId
        stage = .downloadingModel(progress: -1)
        let result = await client.prefetch(modelId: modelId) { [weak self] p in
            Task { @MainActor in self?.stage = .downloadingModel(progress: p) }
        }
        if case .failure(let err) = result {
            throw err
        }
    }

    // MARK: - Process helpers

    private func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = pipe

                // Drain incrementally so subprocesses with verbose output
                // can't block on a full pipe buffer.
                let bufferLock = NSLock()
                var collected = Data()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    bufferLock.lock()
                    if collected.count < 64 * 1024 {
                        collected.append(chunk.prefix(64 * 1024 - collected.count))
                    }
                    bufferLock.unlock()
                }

                do {
                    try process.run()
                    // Bound the wait: a wedged subprocess (e.g. launchctl not
                    // returning) is force-terminated so install() can never hang.
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if process.isRunning { process.terminate() }
                        }
                    }
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus != 0 {
                        let msg = String(data: collected, encoding: .utf8) ?? ""
                        AppLogger.log("subprocess failed (exit \(process.terminationStatus)): \(executable)")
                        AppLogger.log("output: \(msg.split(separator: "\n").suffix(10).joined(separator: "\n"))")
                        cont.resume(throwing: NSError(
                            domain: "OpenLark.installer", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "\(executable) failed (exit \(process.terminationStatus))"]
                        ))
                    } else {
                        cont.resume()
                    }
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        // Bounded session - NOT URLSession.shared. shared's default
        // timeoutIntervalForResource is 7 days, so a stalled or trickling
        // connection (captive portal, throttled wifi) downloads forever and
        // traps onboarding with no error. timeoutIntervalForRequest is an
        // inactivity timer (fail if no bytes for 60s); timeoutIntervalForResource
        // caps the whole transfer. Either firing throws → stage=.failed → Retry.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900  // 15 min hard cap
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let delegate = DownloadProgressDelegate(progress: progress)
        let (tempURL, _) = try await session.download(from: url, delegate: delegate)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        await MainActor.run { progress(1.0) }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressCallback: @MainActor (Double) -> Void

    init(progress: @MainActor @escaping (Double) -> Void) {
        self.progressCallback = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let p: Double
        if totalBytesExpectedToWrite > 0 {
            p = max(0, min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        } else {
            p = 0
        }
        let cb = progressCallback
        Task { @MainActor in cb(p) }
    }

    // Required by URLSessionDownloadDelegate but unused. The async download()
    // variant handles file placement; we just move the returned tempURL.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
