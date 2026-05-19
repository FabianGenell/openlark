import Foundation

/// Simple line-oriented file logger so we can debug without terminal stderr capture.
/// Writes to ~/Library/Logs/OpenLark/app.log, rotating when over 1 MB.
enum AppLogger {
    private static let queue = DispatchQueue(label: "openlark.logger", qos: .utility)
    private static let logURL: URL = {
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

    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let stamp = formatter.string(from: Date())
        let basename = (file as NSString).lastPathComponent
        let entry = "\(stamp) [\(basename):\(line)] \(message)\n"
        NSLog("%@", message)
        queue.async {
            rotateIfNeeded()
            if let data = entry.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size > 1_000_000 else { return }
        let backup = logURL.deletingLastPathComponent()
            .appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: logURL, to: backup)
    }
}
