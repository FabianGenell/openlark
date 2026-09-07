import Foundation

/// Process-wide record of which models are on disk, and the one place that
/// downloads or deletes them.
///
/// The menu bar dropdown needs the downloaded set synchronously when it opens
/// (to build the "Model" submenu showing only downloaded models). Querying the
/// sidecar every time the menu opens would race the menu open, so we keep a
/// cached set and refresh on app launch and after every download or delete.
///
/// Downloads live here rather than in a view model because two screens start
/// them: the Models catalog, and picking a model that isn't on disk inside a
/// polish profile. Sharing the state means a download begun on one is already
/// showing as in-flight on the other.
@MainActor
final class DownloadedModelsCache: ObservableObject {
    static let shared = DownloadedModelsCache()

    @Published private(set) var downloadedIds: Set<String> = []
    @Published private(set) var inFlight: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// 0...1 while a download runs, from bytes actually on disk.
    @Published private(set) var progress: [String: Double] = [:]
    /// Seconds left, estimated from how fast the fraction is actually moving.
    @Published private(set) var etaSeconds: [String: Double] = [:]
    /// Megabytes on disk per model, so a part-finished download reads as
    /// resumable instead of looking like it never started.
    @Published private(set) var onDiskMB: [String: Int] = [:]

    private let client = SidecarClient()
    private var refreshTask: Task<Void, Never>?
    /// Recent (time, fraction) readings per model, for the estimate.
    private var samples: [String: [(at: Date, value: Double)]] = [:]

    /// Transport failures worth retrying by themselves. A download can die
    /// through no fault of its own - the daemon's watchdog force-exits the
    /// process when an unrelated request wedges, and that takes any download
    /// with it. Making the user notice and click again is a poor answer when
    /// the daemon is back within seconds.
    private static let retryAttempts = 3
    private static let retryDelay: Duration = .seconds(4)

    private init() {}

    func isDownloading(_ modelId: String) -> Bool { inFlight.contains(modelId) }

    /// The daemon reports a fraction rather than a rate, so the rate comes from
    /// watching the fraction. A short trailing window rather than an average
    /// since the start, so the estimate follows a connection that speeds up or
    /// slows down instead of being anchored to how it began.
    private func note(progress value: Double, for modelId: String) {
        self.progress[modelId] = value

        var window = samples[modelId] ?? []
        window.append((at: Date(), value: value))
        let cutoff = Date().addingTimeInterval(-60)
        window.removeAll { $0.at < cutoff }
        samples[modelId] = window

        guard let first = window.first, let last = window.last else { return }
        let elapsed = last.at.timeIntervalSince(first.at)
        let gained = last.value - first.value
        // Downloads land in bursts, so a short window or a flat one says
        // nothing useful yet. Better no estimate than a wild one.
        guard elapsed >= 10, gained > 0.0005 else { return }
        let remaining = max(0, 1 - last.value)
        etaSeconds[modelId] = remaining / (gained / elapsed)
    }

    private static func isWorthRetrying(_ error: Error) -> Bool {
        switch error {
        case SidecarClient.SidecarError.connectFailed,
             SidecarClient.SidecarError.recvEOF,
             SidecarClient.SidecarError.timedOut,
             SidecarClient.SidecarError.malformed:
            return true
        default:
            // A server-side error is the daemon's considered answer - an
            // unknown model, no disk space, a dead repo. Retrying just repeats it.
            return false
        }
    }

    /// Idempotent: asking for a model already downloading, or already on disk,
    /// does nothing.
    func download(_ modelId: String) async {
        guard !inFlight.contains(modelId), !downloadedIds.contains(modelId) else { return }
        AppLogger.log("download requested: \(modelId)")
        inFlight.insert(modelId)
        errors[modelId] = nil
        progress[modelId] = 0
        defer {
            inFlight.remove(modelId)
            progress[modelId] = nil
            etaSeconds[modelId] = nil
            samples[modelId] = nil
        }

        var lastError: Error?
        for attempt in 1...Self.retryAttempts {
            let result = await client.prefetch(modelId: modelId) { value in
                guard value >= 0 else { return }
                Task { @MainActor in self.note(progress: value, for: modelId) }
            }
            switch result {
            case .success:
                downloadedIds.insert(modelId)
                lastError = nil
            case .failure(let error):
                lastError = error
            }
            guard let error = lastError, Self.isWorthRetrying(error) else { break }
            // Start the estimate over: readings from the attempt that just
            // failed would otherwise be averaged into the retry's first few.
            samples[modelId] = nil
            etaSeconds[modelId] = nil
            progress[modelId] = 0
            if attempt < Self.retryAttempts {
                AppLogger.log("download \(modelId) dropped (\(error)), retrying \(attempt + 1)/\(Self.retryAttempts)")
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
        if let lastError {
            errors[modelId] = "\(lastError)"
            AppLogger.log("download failed: \(modelId): \(lastError)")
        }
        // Either way, re-read what's on disk so a failure still shows how far
        // it got and the next attempt is offered as a resume.
        await refreshNow()
    }

    func delete(_ modelId: String) async {
        errors[modelId] = nil
        switch await client.deleteModel(modelId: modelId) {
        case .success:
            downloadedIds.remove(modelId)
        case .failure(let error):
            errors[modelId] = "\(error)"
        }
    }

    /// Awaitable refresh, for a view that wants the list settled before it draws.
    func refreshNow() async {
        if case .success(let list) = await client.listModels() {
            apply(list)
        }
    }

    /// Downloads outlive the app now, so anything the daemon says is running
    /// gets shown as in-flight even if this launch didn't start it, and gets
    /// re-attached so its progress and completion are still reported.
    private func apply(_ list: [SidecarClient.RemoteModelStatus]) {
        downloadedIds = Set(list.filter { $0.downloaded }.map { $0.id })
        onDiskMB = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.onDiskMB) })
        // A model the daemon now reports as on disk can't still be failing.
        for id in downloadedIds { errors[id] = nil }
        for model in list where model.downloading && !inFlight.contains(model.id) {
            Task { await download(model.id) }
        }
    }

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
                apply(list)
            }
        }
    }
}
