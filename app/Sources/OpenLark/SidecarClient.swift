import Darwin
import Foundation

/// IPC client for the Python inference daemon.
///
/// Wire format (v2):
///   REQUEST:
///     [4 bytes BE]  header_len
///     [N bytes]     UTF-8 JSON  { "cmd": "transcribe"|"prefetch"|"models"|"ping", ... }
///     If cmd == "transcribe":
///       [4 bytes BE]  audio_len
///       [N bytes]     WAV-encoded audio (16 kHz mono PCM)
///
///   RESPONSE: one or more length-prefixed UTF-8 JSON frames. Connection
///   closes after the terminal frame.
actor SidecarClient {
    enum SidecarError: Error {
        case socketCreate
        case connectFailed(Int32)
        case sendFailed
        case recvEOF
        case timedOut
        case malformed(String)
        case serverError(String)
    }

    private let socketPath: String

    init(socketPath: String = "/tmp/openlark.sock") {
        self.socketPath = socketPath
    }

    /// Kill and respawn the inference daemon via launchd. Used to self-heal
    /// when a request times out (the daemon is wedged but still holding the
    /// socket). `kickstart -k` terminates the running instance; KeepAlive in
    /// the launchd plist brings a fresh one back within ~2s.
    nonisolated static func restartDaemon() {
        // Runs on a background queue: launchctl + waitUntilExit must never block
        // the main actor (it's called from the transcription failure path).
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["kickstart", "-k", "gui/\(getuid())/app.openlark.sidecar"]
            do {
                try task.run()
                task.waitUntilExit()
                AppLogger.log("restartDaemon: launchctl kickstart exit=\(task.terminationStatus)")
            } catch {
                AppLogger.log("restartDaemon: failed to launch launchctl: \(error)")
            }
        }
    }

    // MARK: - Transcribe

    func transcribe(
        wav: Data,
        modelId: String,
        languages: [String]
    ) async -> Result<String, Error> {
        do {
            let header: [String: Any] = [
                "cmd": "transcribe",
                "model": modelId,
                "languages": languages,
            ]
            // 90s covers a cold model load plus inference. The daemon's own
            // watchdog fires at 180s, so the app gives up first and can restart it.
            let response = try sendRequest(
                header: header, audio: wav, expectMultiFrame: false, recvTimeout: 90
            )
            guard let first = response.first else {
                return .failure(SidecarError.recvEOF)
            }
            if let err = first["message"] as? String, (first["event"] as? String) == "error" {
                return .failure(SidecarError.serverError(err))
            }
            if let text = first["text"] as? String {
                return .success(text)
            }
            return .failure(SidecarError.malformed("missing 'text' in response"))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Ping

    /// Round-trips a ping to confirm the daemon is not just bound to the socket
    /// but actually serving. Bounded to 5s so a wedged daemon reports unhealthy
    /// instead of blocking the caller.
    func ping() async -> Bool {
        do {
            let frames = try sendRequest(
                header: ["cmd": "ping"], audio: nil, expectMultiFrame: false, recvTimeout: 5
            )
            return (frames.first?["event"] as? String) == "pong"
        } catch {
            return false
        }
    }

    // MARK: - Models list

    struct RemoteModelStatus: Sendable {
        let id: String
        let downloaded: Bool
        let sizeMB: Int
        let multilingual: Bool
        let backend: String
    }

    func listModels() async -> Result<[RemoteModelStatus], Error> {
        do {
            let frames = try sendRequest(
                header: ["cmd": "models"], audio: nil, expectMultiFrame: false, recvTimeout: 60
            )
            guard let first = frames.first,
                  let raw = first["models"] as? [[String: Any]] else {
                return .failure(SidecarError.malformed("missing 'models' in response"))
            }
            let parsed = raw.compactMap { dict -> RemoteModelStatus? in
                guard let id = dict["id"] as? String else { return nil }
                return RemoteModelStatus(
                    id: id,
                    downloaded: (dict["downloaded"] as? Bool) ?? false,
                    sizeMB: (dict["sizeMB"] as? Int) ?? 0,
                    multilingual: (dict["multilingual"] as? Bool) ?? false,
                    backend: (dict["backend"] as? String) ?? "parakeet"
                )
            }
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Delete

    func deleteModel(modelId: String) async -> Result<Void, Error> {
        do {
            let frames = try sendRequest(
                header: ["cmd": "delete", "model": modelId],
                audio: nil,
                expectMultiFrame: false,
                recvTimeout: 120
            )
            if let first = frames.first,
               (first["event"] as? String) == "error",
               let msg = first["message"] as? String {
                return .failure(SidecarError.serverError(msg))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Prefetch (download a model without transcribing)

    /// Streams progress events. `progress` callback fires on the actor thread.
    /// Hop to MainActor inside if you need to update UI.
    func prefetch(
        modelId: String,
        onProgress: @escaping (Double) -> Void
    ) async -> Result<Void, Error> {
        do {
            // The daemon emits a progress heartbeat every ~5s during the
            // download, so a 60s per-recv timeout resets on each frame and only
            // trips on a genuine stall (no frame for 60s) rather than hanging
            // forever on a dead connection.
            let frames = try sendRequest(
                header: ["cmd": "prefetch", "model": modelId],
                audio: nil,
                expectMultiFrame: true,
                recvTimeout: 60,
                onFrame: { frame in
                    let event = frame["event"] as? String ?? ""
                    if event == "progress" {
                        let v = frame["value"] as? Double ?? -1.0
                        onProgress(v)
                    }
                }
            )
            // Success requires the terminal "done" frame. If the stream ended
            // on an error frame - or just EOF'd after progress (daemon died /
            // download interrupted) - treat it as a failure so the model is not
            // falsely marked downloaded and the UI can offer retry.
            guard let last = frames.last else {
                return .failure(SidecarError.recvEOF)
            }
            let lastEvent = last["event"] as? String
            if lastEvent == "error" {
                return .failure(SidecarError.serverError((last["message"] as? String) ?? "download failed"))
            }
            if lastEvent != "done" {
                return .failure(SidecarError.malformed("download ended without completing"))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Wire

    /// Returns all received frames in order. If `expectMultiFrame` is false,
    /// reads exactly one frame. Otherwise reads until EOF (server closes
    /// after the terminal frame).
    /// - Parameter recvTimeout: per-recv wall-clock limit in seconds. If the
    ///   daemon accepts the connection but never replies (wedged mid-request),
    ///   recv unblocks with `.timedOut` instead of hanging forever. Pass 0 to
    ///   disable (used for prefetch, whose downloads legitimately run long).
    private func sendRequest(
        header: [String: Any],
        audio: Data?,
        expectMultiFrame: Bool,
        recvTimeout: TimeInterval = 0,
        onFrame: ((_ frame: [String: Any]) -> Void)? = nil
    ) throws -> [[String: Any]] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw SidecarError.socketCreate }
        defer { close(fd) }

        if recvTimeout > 0 {
            var tv = timeval(
                tv_sec: Int(recvTimeout),
                tv_usec: Int32((recvTimeout - Double(Int(recvTimeout))) * 1_000_000)
            )
            let tvSize = socklen_t(MemoryLayout<timeval>.size)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = CChar(byte)
                }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if connectResult != 0 {
            throw SidecarError.connectFailed(errno)
        }

        // Send: header_len || header_json || [audio_len || audio]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [])
        var out = Data()
        out.append(contentsOf: bigEndianBytes(UInt32(headerData.count)))
        out.append(headerData)
        if let audio {
            out.append(contentsOf: bigEndianBytes(UInt32(audio.count)))
            out.append(audio)
        }
        try sendAll(fd: fd, data: out)

        // Read frames.
        var frames: [[String: Any]] = []
        while true {
            guard let header = try recvExactOrNil(fd: fd, count: 4) else { break }
            let bodyLen = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            if bodyLen == 0 || bodyLen > 16 * 1024 * 1024 {
                throw SidecarError.malformed("bogus frame length \(bodyLen)")
            }
            let body = try recvExact(fd: fd, count: Int(bodyLen))
            guard let obj = try JSONSerialization.jsonObject(
                with: body, options: []
            ) as? [String: Any] else {
                throw SidecarError.malformed("frame is not a JSON object")
            }
            frames.append(obj)
            onFrame?(obj)
            if !expectMultiFrame { break }
        }
        return frames
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(
                    fd,
                    raw.baseAddress!.advanced(by: sent),
                    data.count - sent,
                    0
                )
                if result <= 0 { throw SidecarError.sendFailed }
                sent += result
            }
        }
    }

    private func recvExact(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var got = 0
            while got < count {
                let result = Darwin.recv(
                    fd,
                    raw.baseAddress!.advanced(by: got),
                    count - got,
                    0
                )
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw SidecarError.timedOut
                }
                if result <= 0 { throw SidecarError.recvEOF }
                got += result
            }
        }
        return data
    }

    /// Like recvExact, but returns nil on clean EOF before reading any byte
    /// (used to detect end of multi-frame stream).
    private func recvExactOrNil(fd: Int32, count: Int) throws -> Data? {
        var data = Data(count: count)
        var clean = false
        try data.withUnsafeMutableBytes { raw in
            var got = 0
            while got < count {
                let result = Darwin.recv(
                    fd,
                    raw.baseAddress!.advanced(by: got),
                    count - got,
                    0
                )
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw SidecarError.timedOut
                }
                if result == 0 && got == 0 {
                    clean = true
                    return
                }
                if result <= 0 { throw SidecarError.recvEOF }
                got += result
            }
        }
        return clean ? nil : data
    }
}
