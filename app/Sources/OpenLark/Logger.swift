import Foundation

/// Simple line-oriented file logger. Writes to ~/Library/Logs/OpenLark/app.log,
/// rotating when over 1 MB. Keeps a single FileHandle open for the lifetime of
/// the process so burst logging from audio callbacks doesn't spin up syscalls.
enum AppLogger {
    private static let queue = DispatchQueue(label: "openlark.logger", qos: .utility)

    nonisolated(unsafe) private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OpenLark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Persistent handle to the log file. Created lazily; reopened automatically
    /// after a rotation. Access only through the serial logger queue.
    nonisolated(unsafe) private static var handle: FileHandle? = nil

    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let stamp = formatter.string(from: Date())
        let basename = (file as NSString).lastPathComponent
        let entry = "\(stamp) [\(basename):\(line)] \(message)\n"
        NSLog("%@", message)
        queue.async {
            rotateIfNeeded()
            guard let data = entry.data(using: .utf8) else { return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: logURL)
                try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: data)
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size > 1_000_000 else { return }
        try? handle?.close()
        handle = nil
        let backup = logURL.deletingLastPathComponent()
            .appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: logURL, to: backup)
    }
}
