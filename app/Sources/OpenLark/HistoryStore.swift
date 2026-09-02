import Foundation

struct TranscriptEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    /// Frontmost-app name at the moment the recording was completed, if known.
    /// Optional for backward-compat, entries created before this field decode as nil.
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

/// Running lifetime tally. Kept separately from `entries` because the entry
/// list is capped at `HistoryStore.maxEntries`, so anything derived from it
/// means "the last 50 transcriptions", not "all time".
struct LifetimeTotals: Codable, Equatable {
    var words: Int = 0
    var recordedSeconds: Double = 0
    var transcriptions: Int = 0

    static let zero = LifetimeTotals()
}

/// Derived usage statistics. The weekly figures come from the retained
/// entries; the all-time figures come from the lifetime tally.
struct UsageStats: Equatable {
    /// Average dictation speed over everything ever recorded, in words/minute.
    let averageWPM: Double
    /// Words dictated within the last 7 days.
    let wordsThisWeek: Int
    /// Words dictated since the app was installed.
    let wordsAllTime: Int
    /// Estimated time saved this week vs typing at the baseline rate.
    let timeSavedThisWeek: TimeInterval
    /// Estimated time saved since install vs typing at the baseline rate.
    let timeSavedAllTime: TimeInterval

    static let zero = UsageStats(
        averageWPM: 0,
        wordsThisWeek: 0,
        wordsAllTime: 0,
        timeSavedThisWeek: 0,
        timeSavedAllTime: 0
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
    @Published private(set) var totals: LifetimeTotals = .zero

    private let fileURL: URL
    private let totalsURL: URL

    init(fileURL: URL? = nil) {
        let resolved: URL
        if let fileURL {
            resolved = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenLark", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            resolved = support.appendingPathComponent("history.json")
        }
        self.fileURL = resolved
        self.totalsURL = resolved
            .deletingLastPathComponent()
            .appendingPathComponent("totals.json")
        load()
        loadTotals()
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

        // Counted before any trimming, so the lifetime figures survive entries
        // ageing out of the list.
        totals.words += trimmed.split(whereSeparator: { $0.isWhitespace }).count
        totals.recordedSeconds += durationSeconds
        totals.transcriptions += 1

        save()
        saveTotals()
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
        guard !entries.isEmpty || totals.transcriptions > 0 else { return .zero }

        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let weekEntries = entries.filter { $0.timestamp >= weekAgo }

        let wordsThisWeek = weekEntries.reduce(0) { $0 + $1.wordCount }
        let secondsThisWeek = weekEntries.reduce(0.0) { $0 + $1.durationSeconds }

        let lifetimeMinutes = totals.recordedSeconds / 60.0
        let avgWPM = lifetimeMinutes > 0 ? Double(totals.words) / lifetimeMinutes : 0

        return UsageStats(
            averageWPM: avgWPM,
            wordsThisWeek: wordsThisWeek,
            wordsAllTime: totals.words,
            timeSavedThisWeek: Self.timeSaved(words: wordsThisWeek, spentSeconds: secondsThisWeek),
            timeSavedAllTime: Self.timeSaved(words: totals.words, spentSeconds: totals.recordedSeconds)
        )
    }

    /// Time typing these words would have taken at the baseline rate, minus
    /// the time actually spent dictating them.
    private static func timeSaved(words: Int, spentSeconds: Double) -> TimeInterval {
        let typingSeconds = (Double(words) / typingBaselineWPM) * 60.0
        return max(0, typingSeconds - spentSeconds)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { return }
        entries = decoded
    }

    private func loadTotals() {
        if let data = try? Data(contentsOf: totalsURL),
           let decoded = try? JSONDecoder().decode(LifetimeTotals.self, from: data) {
            totals = decoded
            reconcileTotalsWithEntries()
            return
        }
        // First run after this shipped. Seed from the retained entries so the
        // all-time figures don't start at zero for an existing install. This
        // undercounts anyone who has already dictated more than maxEntries
        // times, which is the best available: the older transcripts are gone.
        guard !entries.isEmpty else { return }
        totals = LifetimeTotals(
            words: entries.reduce(0) { $0 + $1.wordCount },
            recordedSeconds: entries.reduce(0.0) { $0 + $1.durationSeconds },
            transcriptions: entries.count
        )
        saveTotals()
    }

    /// The retained entries are a lower bound on the lifetime figures. If they
    /// account for more than the tally does, the tally is behind: it was seeded
    /// before those entries existed, or they were recorded by a build that had
    /// no tally. Without this, "all time" can read lower than "this week".
    private func reconcileTotalsWithEntries() {
        let entriesWords = entries.reduce(0) { $0 + $1.wordCount }
        guard entriesWords > totals.words else { return }
        totals.words = entriesWords
        totals.recordedSeconds = max(
            totals.recordedSeconds,
            entries.reduce(0.0) { $0 + $1.durationSeconds }
        )
        totals.transcriptions = max(totals.transcriptions, entries.count)
        saveTotals()
    }

    private func saveTotals() {
        guard let data = try? JSONEncoder().encode(totals) else { return }
        try? data.write(to: totalsURL, options: .atomic)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
