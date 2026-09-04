import Combine
import Foundation

/// A named polish instruction. The cleanup itself never changes; a profile is
/// the part on top of it, so "Email" and "WhatsApp" are the same tidy-up with a
/// different register asked for at the end.
struct PolishProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var instruction: String
    /// Model this profile polishes with. Every profile names one outright:
    /// a longer, more careful model for email, the quick one for chat. There is
    /// no app-wide fallback to keep in sync with it.
    var modelId: String
    /// 0 is greedy: the same dictation always polishes the same way. Higher
    /// lets the model pick less-likely wordings, which is worth something for a
    /// profile that rewrites register and nothing for one that just tidies.
    var temperature: Double

    init(
        id: UUID = UUID(),
        name: String,
        instruction: String = "",
        modelId: String = PolishRegistry.defaultModelId,
        temperature: Double = 0
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.modelId = modelId
        self.temperature = temperature
    }

    enum CodingKeys: String, CodingKey { case id, name, instruction, modelId, temperature }

    /// Profiles written before models were per-profile have no `modelId`, or a
    /// null one from when it was optional. Both land on the registry default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? PolishRegistry.defaultModelId
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
    }
}

private struct PolishProfileFile: Codable {
    var profiles: [PolishProfile]
    var activeId: UUID?
}

@MainActor
final class PolishProfileStore: ObservableObject {
    static let shared = PolishProfileStore()

    @Published private(set) var profiles: [PolishProfile] = []
    @Published private(set) var activeId: UUID?

    /// Key the pre-profiles build wrote a single instruction to. Read once at
    /// first load so nobody loses what they had typed, then left alone.
    private static let legacyInstructionKey = "polishInstruction"

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenLark", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("polish-profiles.json")
        }
        load()
    }

    /// The profile whose instruction is applied. Never nil once loaded: an
    /// empty list is seeded with one profile so polish always has something to
    /// run, even if that something is the plain cleanup.
    var active: PolishProfile? {
        guard let activeId else { return profiles.first }
        return profiles.first { $0.id == activeId } ?? profiles.first
    }

    var activeInstruction: String {
        (active?.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model the active profile polishes with.
    var activeModelId: String {
        active?.modelId ?? PolishRegistry.defaultModelId
    }

    var activeTemperature: Double { active?.temperature ?? 0 }

    /// How many profiles point at a model, so the catalog can warn before
    /// deleting one that something still uses.
    func profileCount(usingModel modelId: String) -> Int {
        profiles.filter { $0.modelId == modelId }.count
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String = "New profile", instruction: String = "") -> PolishProfile {
        let profile = PolishProfile(name: uniqueName(from: name), instruction: instruction)

        profiles.append(profile)
        activeId = profile.id
        save()
        return profile
    }

    func update(_ profile: PolishProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    func remove(_ profile: PolishProfile) {
        profiles.removeAll { $0.id == profile.id }
        // Never leave the list empty; polish would have no instruction to read
        // and the page would have nothing to show.
        if profiles.isEmpty {
            profiles = [PolishProfile(name: "Default")]
        }
        if activeId == profile.id {
            activeId = profiles.first?.id
        }
        save()
    }

    func setActive(_ profile: PolishProfile) {
        activeId = profile.id
        save()
    }

    func duplicate(_ profile: PolishProfile) {
        let copy = PolishProfile(
            name: uniqueName(from: profile.name + " copy"),
            instruction: profile.instruction,
            modelId: profile.modelId,
            temperature: profile.temperature
        )
        profiles.append(copy)
        activeId = copy.id
        save()
    }

    /// Two profiles called the same thing are indistinguishable in the menu bar,
    /// where there's no instruction preview to tell them apart.
    private func uniqueName(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "New profile" : trimmed
        guard profiles.contains(where: { $0.name == candidate }) else { return candidate }
        var n = 2
        while profiles.contains(where: { $0.name == "\(candidate) \(n)" }) { n += 1 }
        return "\(candidate) \(n)"
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PolishProfileFile.self, from: data),
           !decoded.profiles.isEmpty {
            profiles = decoded.profiles
            activeId = decoded.activeId ?? decoded.profiles.first?.id
            return
        }

        let carried = (UserDefaults.standard.string(forKey: Self.legacyInstructionKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = PolishProfile(name: "Default", instruction: carried)
        profiles = [seed]
        activeId = seed.id
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(
            PolishProfileFile(profiles: profiles, activeId: activeId)
        ) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
