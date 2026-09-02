import Foundation
import Combine

/// A vocabulary entry. If `replacement` is nil this is a "preserve casing" word
/// (e.g. "Heltra", when Parakeet returns "heltra" we want to fix the case).
/// If `replacement` is set this is a snippet, "weboo" → "webbu", replace
/// the source token verbatim with the replacement.
struct VocabEntry: Codable, Identifiable, Hashable {
    var id: String { source }
    var source: String
    var replacement: String?

    var isSnippet: Bool { replacement != nil }
    /// The canonical form to emit when this entry matches.
    var canonical: String { replacement ?? source }
}

@MainActor
final class VocabStore: ObservableObject {
    static let shared = VocabStore()

    @Published private(set) var entries: [VocabEntry] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenLark", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("vocab.json")
        }
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VocabEntry].self, from: data) {
            entries = decoded.sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
            return
        }
        entries = Self.seed.sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ entry: VocabEntry) {
        if let i = entries.firstIndex(where: { $0.source.caseInsensitiveCompare(entry.source) == .orderedSame }) {
            entries[i] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
        }
        save()
    }

    func remove(_ entry: VocabEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func update(original: VocabEntry, to new: VocabEntry) {
        if let i = entries.firstIndex(where: { $0.id == original.id }) {
            entries[i] = new
            entries.sort { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
            save()
        }
    }

    // MARK: - Correction

    /// Apply vocab + snippet corrections to a raw transcription.
    func correct(_ text: String) -> String {
        VocabCorrector.correct(text: text, entries: entries)
    }

    // MARK: - Seed

    /// Default vocabulary shipped with the app. Mostly common developer terms
    /// that ASR models tend to mangle. Users can add their own from the menu
    /// bar → Vocabulary…
    static let seed: [VocabEntry] = [
        .init(source: "GitHub"),
        .init(source: "GraphQL"),
        .init(source: "npm"),
        .init(source: "Postgres"),
        .init(source: "TypeScript"),
        .init(source: "JavaScript"),
        .init(source: "Vite"),
        .init(source: "webpack"),
        .init(source: "Webhook"),
    ]
}
