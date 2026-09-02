import Foundation

/// One row in the model picker.
struct ModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String                  // canonical id sent to the sidecar
    let displayName: String
    let backend: Backend
    let approxSizeMB: Int           // real download size, not parameter count
    /// How many languages the model actually recognises. 1 means English-only.
    let languageCount: Int
    let speedLabel: String          // "Fastest", "Fast", "Balanced", "Best quality"
    let summary: String             // one-line tagline shown in the picker
    let recommendedDefault: Bool

    enum Backend: String, Sendable { case parakeet, whisper }

    var multilingual: Bool { languageCount > 1 }
}

enum ModelRegistry {
    /// The shipped catalog. Order matters. This is the order shown in
    /// Settings → Models.
    static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            backend: .parakeet,
            approxSizeMB: 2472,
            languageCount: 1,
            speedLabel: "Fastest",
            summary: "NVIDIA's TDT 0.6B, ~25× realtime on Apple Silicon. Best English accuracy.",
            recommendedDefault: true
        ),
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            backend: .parakeet,
            approxSizeMB: 2508,
            languageCount: 25,
            speedLabel: "Fastest",
            summary: "Same speed as v2 across 25 European languages, for a shade less English accuracy.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "parakeet-tdt-ctc-110m",
            displayName: "Parakeet TDT-CTC 110M",
            backend: .parakeet,
            approxSizeMB: 459,
            languageCount: 1,
            speedLabel: "Fastest",
            summary: "Smallest download. Good on clear speech, weaker on accents and noise.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "parakeet-tdt-1.1b",
            displayName: "Parakeet TDT 1.1B",
            backend: .parakeet,
            approxSizeMB: 4282,
            languageCount: 1,
            speedLabel: "Fast",
            summary: "Larger Parakeet, better on long and technical speech.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            backend: .whisper,
            approxSizeMB: 1614,
            languageCount: 99,
            speedLabel: "Fast",
            summary: "Broadest language coverage at a usable speed.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-large-v3-turbo-q4",
            displayName: "Whisper Large v3 Turbo (4-bit)",
            backend: .whisper,
            approxSizeMB: 464,
            languageCount: 99,
            speedLabel: "Fast",
            summary: "Same model quantised to a quarter of the download, for a little accuracy.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-large-v3",
            displayName: "Whisper Large v3",
            backend: .whisper,
            approxSizeMB: 3084,
            languageCount: 99,
            speedLabel: "Best quality",
            summary: "Highest accuracy. Slower than turbo, bigger download.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            backend: .whisper,
            approxSizeMB: 1525,
            languageCount: 99,
            speedLabel: "Balanced",
            summary: "Good middle ground between speed and accuracy.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-small",
            displayName: "Whisper Small",
            backend: .whisper,
            approxSizeMB: 481,
            languageCount: 99,
            speedLabel: "Fast",
            summary: "Light on disk, noticeably less accurate than the large models.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "distil-whisper-large-v3",
            displayName: "Distil-Whisper Large v3",
            backend: .whisper,
            approxSizeMB: 1509,
            languageCount: 1,
            speedLabel: "Fast",
            summary: "Distillation of Whisper Large, very fast.",
            recommendedDefault: false
        ),
    ]

    static let defaultModelId = "parakeet-tdt-0.6b-v2"

    static func find(_ id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }
}
