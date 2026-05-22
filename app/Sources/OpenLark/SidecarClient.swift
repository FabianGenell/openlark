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
        case malformed(String)
        case serverError(String)
    }

    private let socketPath: String

    init(socketPath: String = "/tmp/openlark.sock") {
        self.socketPath = socketPath
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
            let response = try sendRequest(header: header, audio: wav, expectMultiFrame: false)
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
                header: ["cmd": "models"], audio: nil, expectMultiFrame: false
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
                expectMultiFrame: false
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

    /// Streams progress events. `progress` callback fires on the actor thread —
    /// hop to MainActor inside if you need to update UI.
    func prefetch(
        modelId: String,
        onProgress: @escaping (Double) -> Void
    ) async -> Result<Void, Error> {
        do {
            let frames = try sendRequest(
                header: ["cmd": "prefetch", "model": modelId],
                audio: nil,
                expectMultiFrame: true,
                onFrame: { frame in
                    let event = frame["event"] as? String ?? ""
                    if event == "progress" {
                        let v = frame["value"] as? Double ?? -1.0
                        onProgress(v)
                    }
                }
            )
            // Final frame should be "done" or "error".
            if let last = frames.last,
               (last["event"] as? String) == "error",
               let msg = last["message"] as? String {
                return .failure(SidecarError.serverError(msg))
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
    private func sendRequest(
        header: [String: Any],
        audio: Data?,
        expectMultiFrame: Bool,
        onFrame: ((_ frame: [String: Any]) -> Void)? = nil
    ) throws -> [[String: Any]] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw SidecarError.socketCreate }
        defer { close(fd) }

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
