import Foundation

/// Process-wide cache of which models are currently downloaded.
///
/// The menu bar dropdown needs this synchronously when it opens (to build
/// the "Model" submenu showing only downloaded models). Querying the sidecar
/// every time the menu opens would race the menu open, so instead we keep a
/// cached set and refresh on app launch + after every download/delete from
/// the Settings UI.
@MainActor
final class DownloadedModelsCache: ObservableObject {
    static let shared = DownloadedModelsCache()

    @Published private(set) var downloadedIds: Set<String> = []

    private let client = SidecarClient()
    private var refreshTask: Task<Void, Never>?

    private init() {}

    /// Returns models from the registry that are downloaded, in registry order.
    func downloadedModels() -> [ModelDescriptor] {
        ModelRegistry.all.filter { downloadedIds.contains($0.id) }
    }

    /// Trigger a background refresh. Idempotent, coalesces concurrent calls.
    func refresh() {
        if refreshTask != nil { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            let result = await client.listModels()
            if case .success(let list) = result {
                let next = Set(list.filter { $0.downloaded }.map { $0.id })
                if next != downloadedIds {
                    downloadedIds = next
                }
            }
        }
    }
}
