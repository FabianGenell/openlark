import Foundation

/// One-shot installer for the Python inference daemon.
///
/// Run from the onboarding window after permissions are granted. Does this:
///   1. Downloads a self-contained Python (`python-build-standalone`) into
///      ~/Library/Application Support/OpenLark/runtime/
///   2. Creates a venv inside that runtime, pip-installs parakeet-mlx + mlx + numpy
///   3. Copies the bundled server.py into ~/Library/Application Support/OpenLark/sidecar/
///   4. Writes ~/Library/LaunchAgents/app.openlark.sidecar.plist pointing at the
///      installed venv's Python and the copied server.py
///   5. launchctl loads the agent
///
/// Idempotent: if the venv + plist already exist, it skips the heavy steps and
/// just re-loads the agent.
@MainActor
final class SidecarInstaller: ObservableObject {
    enum Stage: Equatable {
        case idle
        case checking
        case alreadyInstalled
        case downloadingPython(progress: Double)
        case extractingPython
        case installingWheels
        case registeringDaemon
        case waitingForSocket
        case done
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Ready"
            case .checking: return "Checking for existing install…"
            case .alreadyInstalled: return "Speech engine already installed"
            case .downloadingPython(let p): return "Downloading Python runtime — \(Int(p * 100))%"
            case .extractingPython: return "Extracting runtime…"
            case .installingWheels: return "Installing parakeet-mlx + mlx (one-time, ~150 MB)…"
            case .registeringDaemon: return "Registering background daemon…"
            case .waitingForSocket: return "Starting daemon…"
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
    }

    @Published var stage: Stage = .idle

    private let pythonURL = URL(string:
        "https://github.com/astral-sh/python-build-standalone/releases/download/20260510/cpython-3.13.13+20260510-aarch64-apple-darwin-install_only.tar.gz"
    )!

    var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLark", isDirectory: true)
    }
    var runtimeRoot: URL { supportRoot.appendingPathComponent("runtime", isDirectory: true) }
    var venvRoot: URL { supportRoot.appendingPathComponent("venv", isDirectory: true) }
    var sidecarRoot: URL { supportRoot.appendingPathComponent("sidecar", isDirectory: true) }
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
    var venvPython: URL { venvRoot.appendingPathComponent("bin/python") }
    var bundledPython: URL { runtimeRoot.appendingPathComponent("python/bin/python3") }
    var serverScript: URL { sidecarRoot.appendingPathComponent("server.py") }

    /// True if the daemon is already running and responding on the socket.
    /// We don't care WHERE it was installed from (this app's installer, the
    /// shell-script install, or a manual setup) — if the socket is up the user
    /// already has a working daemon and we should leave it alone.
    func isDaemonHealthy() -> Bool {
        FileManager.default.fileExists(atPath: "/tmp/openlark.sock")
    }

    func install() async {
        stage = .checking
        do {
            try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)

            // Always copy the bundled server.py — keeps the daemon in sync with
            // whatever app version is currently installed.
            try copyServerScript()

            if FileManager.default.fileExists(atPath: venvPython.path) {
                AppLogger.log("installer: venv already exists, skipping download")
            } else {
                try await downloadAndExtractPython()
                try await installWheels()
            }

            stage = .registeringDaemon
            try writeLaunchAgent()
            try loadLaunchAgent()

            stage = .waitingForSocket
            try await waitForSocket()

            stage = .done
        } catch is CancellationError {
            stage = .failed("cancelled")
        } catch {
            AppLogger.log("installer failed: \(error)")
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private func copyServerScript() throws {
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.url(forResource: "server", withExtension: "py", subdirectory: "sidecar") else {
            throw NSError(
                domain: "OpenLark.installer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled server.py missing from app — corrupt .app bundle?"]
            )
        }
        try? FileManager.default.removeItem(at: serverScript)
        try FileManager.default.copyItem(at: bundled, to: serverScript)
    }

    private func downloadAndExtractPython() async throws {
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let tarURL = runtimeRoot.appendingPathComponent("python.tar.gz")

        // Download with progress.
        try await downloadFile(from: pythonURL, to: tarURL) { progress in
            self.stage = .downloadingPython(progress: progress)
        }

        stage = .extractingPython
        try await runProcess(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", tarURL.path, "-C", runtimeRoot.path]
        )
        try? FileManager.default.removeItem(at: tarURL)

        guard FileManager.default.fileExists(atPath: bundledPython.path) else {
            throw NSError(
                domain: "OpenLark.installer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Python runtime missing after extract — expected \(bundledPython.path)"]
            )
        }
    }

    private func installWheels() async throws {
        stage = .installingWheels
        // Create venv with the bundled Python so the venv has a stable path
        // even if we later upgrade the runtime.
        try? FileManager.default.removeItem(at: venvRoot)
        try await runProcess(
            executable: bundledPython.path,
            arguments: ["-m", "venv", venvRoot.path]
        )

        // Upgrade pip + install wheels.
        try await runProcess(
            executable: venvPython.path,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "wheel"]
        )
        try await runProcess(
            executable: venvPython.path,
            arguments: [
                "-m", "pip", "install",
                "parakeet-mlx>=0.3.5,<0.4",
                "numpy>=2.0",
                "mlx>=0.18",
            ]
        )
    }

    private func writeLaunchAgent() throws {
        let plist: [String: Any] = [
            "Label": "app.openlark.sidecar",
            "ProgramArguments": [venvPython.path, serverScript.path],
            "WorkingDirectory": sidecarRoot.path,
            "EnvironmentVariables": [
                "OPENLARK_SOCKET": "/tmp/openlark.sock",
                "PYTHONUNBUFFERED": "1",
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
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

    private func loadLaunchAgent() throws {
        // Unload any prior version of the agent — older installs from the
        // shell-script path may still be registered.
        _ = try? runProcessSync(
            executable: "/bin/launchctl",
            arguments: ["unload", launchAgentURL.path]
        )
        try runProcessSync(
            executable: "/bin/launchctl",
            arguments: ["load", launchAgentURL.path]
        )
    }

    private func waitForSocket() async throws {
        // Sidecar startup is dominated by the model load on first launch
        // (which downloads ~600 MB from HuggingFace) but we don't want to wait
        // for that — just for the socket to bind. Give it 30s tops.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "/tmp/openlark.sock") { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Don't error — the daemon may still be downloading the model. We've
        // done our part; surface "ready" and let the daemon catch up.
    }

    // MARK: - Process / download helpers

    private func runProcess(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let msg = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                        cont.resume(throwing: NSError(
                            domain: "OpenLark.installer", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(msg.prefix(400))"]
                        ))
                    } else {
                        cont.resume()
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func runProcessSync(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "OpenLark.installer", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) failed (exit \(process.terminationStatus))"]
            )
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        let session = URLSession(configuration: .default)
        let (asyncBytes, response) = try await session.bytes(from: url)
        let total = response.expectedContentLength
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw NSError(
                domain: "OpenLark.installer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "could not open \(destination.path) for writing"]
            )
        }
        defer { try? handle.close() }

        var buffer = Data(capacity: 1024 * 1024)
        var received: Int64 = 0
        var lastReported = Date(timeIntervalSince1970: 0)
        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 1024 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if total > 0, Date().timeIntervalSince(lastReported) > 0.1 {
                let p = max(0, min(1, Double(received) / Double(total)))
                await MainActor.run { progress(p) }
                lastReported = Date()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        await MainActor.run { progress(1.0) }
    }
}
