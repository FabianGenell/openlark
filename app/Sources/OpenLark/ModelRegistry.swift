import Foundation

/// One row in the model picker.
struct ModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String                  // canonical id sent to the sidecar
    let displayName: String
    let backend: Backend
    let approxSizeMB: Int
    let multilingual: Bool
    let speedLabel: String          // "Fastest", "Fast", "Balanced", "Best quality"
    let summary: String             // one-line tagline shown in the picker
    let recommendedDefault: Bool

    enum Backend: String, Sendable { case parakeet, whisper }
}

enum ModelRegistry {
    /// The shipped catalog. Order matters. This is the order shown in
    /// Settings → Models.
    static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            backend: .parakeet,
            approxSizeMB: 600,
            multilingual: false,
            speedLabel: "Fastest",
            summary: "English-only. NVIDIA's TDT 0.6B, ~25× realtime on Apple Silicon.",
            recommendedDefault: true
        ),
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            backend: .parakeet,
            approxSizeMB: 600,
            multilingual: false,
            speedLabel: "Fastest",
            summary: "English-only. Newer TDT 0.6B with improved accuracy.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "parakeet-tdt-1.1b",
            displayName: "Parakeet TDT 1.1B",
            backend: .parakeet,
            approxSizeMB: 1100,
            multilingual: false,
            speedLabel: "Fast",
            summary: "English-only. Larger Parakeet, better on long/technical speech.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            backend: .whisper,
            approxSizeMB: 1600,
            multilingual: true,
            speedLabel: "Fast",
            summary: "Multilingual. Recommended if you speak more than English.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-large-v3",
            displayName: "Whisper Large v3",
            backend: .whisper,
            approxSizeMB: 3100,
            multilingual: true,
            speedLabel: "Best quality",
            summary: "Multilingual. Highest accuracy. Slower than turbo, bigger download.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            backend: .whisper,
            approxSizeMB: 1500,
            multilingual: true,
            speedLabel: "Balanced",
            summary: "Multilingual. Good middle ground between speed and accuracy.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "whisper-small",
            displayName: "Whisper Small",
            backend: .whisper,
            approxSizeMB: 500,
            multilingual: true,
            speedLabel: "Fast",
            summary: "Multilingual. Smallest multilingual option, quick downloads.",
            recommendedDefault: false
        ),
        ModelDescriptor(
            id: "distil-whisper-large-v3",
            displayName: "Distil-Whisper Large v3",
            backend: .whisper,
            approxSizeMB: 1500,
            multilingual: false,
            speedLabel: "Fast",
            summary: "English-only distillation of Whisper Large, very fast.",
            recommendedDefault: false
        ),
    ]

    static let defaultModelId = "parakeet-tdt-0.6b-v2"

    static func find(_ id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }
}
