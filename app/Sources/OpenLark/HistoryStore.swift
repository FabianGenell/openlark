import Foundation

struct TranscriptEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    /// Frontmost-app name at the moment the recording was completed, if known.
    /// Optional for backward-compat — entries created before this field will decode as nil.
    let appName: String?

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        durationSeconds: Double,
        appName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.appName = appName
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Derived usage statistics — computed from the entries list.
struct UsageStats: Equatable {
    /// Average dictation speed across all-time history, in words per minute.
    let averageWPM: Double
    /// Words dictated within the last 7 days.
    let wordsThisWeek: Int
    /// Distinct apps the user dictated into in the last 7 days.
    let appsUsedThisWeek: Int
    /// Estimated time saved this week vs typing at the baseline rate.
    let timeSavedThisWeek: TimeInterval

    static let zero = UsageStats(
        averageWPM: 0,
        wordsThisWeek: 0,
        appsUsedThisWeek: 0,
        timeSavedThisWeek: 0
    )
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 50

    /// Typing baseline (WPM) used to compute time saved. Average adult typing
    /// speed; dictation is typically 3–4× faster, which is where the savings come from.
    static let typingBaselineWPM: Double = 40

    @Published private(set) var entries: [TranscriptEntry] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenLark", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("history.json")
        }
        load()
    }

    func add(text: String, durationSeconds: Double, appName: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(
            TranscriptEntry(
                text: trimmed,
                durationSeconds: durationSeconds,
                appName: appName
            ),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func remove(_ entry: TranscriptEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Stats

    /// Returns derived stats. Cheap to compute; recompute on each view render.
    func stats(now: Date = Date()) -> UsageStats {
        guard !entries.isEmpty else { return .zero }

        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let weekEntries = entries.filter { $0.timestamp >= weekAgo }

        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        let totalMinutes = entries.reduce(0.0) { $0 + ($1.durationSeconds / 60.0) }
        let avgWPM = totalMinutes > 0 ? Double(totalWords) / totalMinutes : 0

        let wordsThisWeek = weekEntries.reduce(0) { $0 + $1.wordCount }

        let apps = Set(weekEntries.compactMap { $0.appName }.filter { !$0.isEmpty })

        // Time it would have taken to type these words at the baseline rate,
        // minus the time it actually took (recording duration).
        let typingSeconds = (Double(wordsThisWeek) / Self.typingBaselineWPM) * 60.0
        let actualSeconds = weekEntries.reduce(0.0) { $0 + $1.durationSeconds }
        let saved = max(0, typingSeconds - actualSeconds)

        return UsageStats(
            averageWPM: avgWPM,
            wordsThisWeek: wordsThisWeek,
            appsUsedThisWeek: apps.count,
            timeSavedThisWeek: saved
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
