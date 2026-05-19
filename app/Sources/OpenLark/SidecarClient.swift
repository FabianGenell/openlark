import Darwin
import Foundation

actor SidecarClient {
    enum SidecarError: Error {
        case socketCreate
        case connectFailed(Int32)
        case sendFailed
        case recvEOF
        case serverError(String)
    }

    private let socketPath: String

    init(socketPath: String = "/tmp/openlark.sock") {
        self.socketPath = socketPath
    }

    func transcribe(wav: Data) async -> Result<String, Error> {
        do {
            let text = try sendAndReceive(wav: wav)
            if text.hasPrefix("__ERROR__") {
                return .failure(SidecarError.serverError(text))
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    private func sendAndReceive(wav: Data) throws -> String {
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

        var header = withUnsafeBytes(of: UInt32(wav.count).bigEndian) { Data($0) }
        header.append(wav)
        try sendAll(fd: fd, data: header)

        let respHeader = try recvExact(fd: fd, count: 4)
        let respLen = respHeader.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let body = try recvExact(fd: fd, count: Int(respLen))
        return String(data: body, encoding: .utf8) ?? ""
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
}
