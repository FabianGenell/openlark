import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Lets callers outside the SwiftUI tree pick which section Settings shows,
/// including when the window is already open.
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var section: SettingsSection = .general
}

enum SettingsWindowFactory {
    @MainActor
    static func make(navigator: SettingsNavigator) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Settings"
        // The palette is built for a dark surface, matching the recording
        // overlay. Pin the appearance so a light-mode system doesn't hand us
        // light system controls on a near-black background.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.window)
        window.isReleasedWhenClosed = false
        window.center()
        let view = NSHostingView(rootView: SettingsRoot(navigator: navigator))
        window.contentView = view
        return window
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case vocabulary = "Vocabulary"
    case models = "Models"
    case languages = "Languages"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gauge.medium"
        case .vocabulary: return "text.book.closed"
        case .models: return "cpu"
        case .languages: return "globe"
        case .about: return "info.circle"
        }
    }
}

/// Manual sidebar+detail layout. NavigationSplitView inside a manually-hosted
/// NSWindow doesn't render reliably (sidebar items can vanish, detail can show
/// transparent), so we hand-roll the split.
struct SettingsRoot: View {
    @ObservedObject var navigator: SettingsNavigator

    private var selection: SettingsSection { navigator.section }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)
                .background(Theme.sidebar)

            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.windowGradient)
        }
        .frame(minWidth: 740, minHeight: 480)
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .tint(Theme.text)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(
                    section: section,
                    isSelected: selection == section
                ) {
                    navigator.section = section
                }
            }
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsPane()
        case .vocabulary:
            VocabSettingsPane(store: VocabStore.shared)
        case .models:
            ModelsSettingsPane()
        case .languages:
            LanguagesSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.chip : (hovered ? Theme.raisedHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Theme.stroke : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - General (with stats)

private struct GeneralSettingsPane: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsScroll {
            StatsCard(stats: history.stats())

            SettingsGroup(title: "Startup") {
                Toggle("Launch OpenLark at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        let service = SMAppService.mainApp
                        do {
                            if newValue {
                                try service.register()
                            } else {
                                try service.unregister()
                            }
                            AppLogger.log("launch-at-login set to \(newValue)")
                        } catch {
                            AppLogger.log("launch-at-login toggle failed: \(error)")
                            launchAtLogin = service.status == .enabled
                        }
                    }
                Text("Starts OpenLark automatically when you log in so the menu bar item is always available.")
                    .settingsHint()
            }

            SettingsGroup(title: "Hotkey") {
                HStack {
                    Text("Toggle recording")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleRecording)
                }
                Text("Tap the field, then press the keys you want. Pick a combination that doesn't clash with apps you use. Modifier + arrow / letter works well.")
                    .settingsHint()
            }
        }
    }
}

// MARK: - Vocabulary

private struct VocabSettingsPane: View {
    @ObservedObject var store: VocabStore
    @State private var input: String = ""
    @State private var snippetTarget: String = ""
    @State private var showingSnippetField: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vocabulary")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Plain words force canonical casing and rescue near-miss phonetic mistakes. Snippets do verbatim replacement.")
                    .settingsHint()

                inputRow
                    .padding(.top, 6)
            }
            .padding(20)

            Divider().opacity(0.15)

            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No custom vocabulary yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            VocabRow(entry: entry, store: store)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Add a word or create a snippet", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(Theme.text)
                .themeField()
                .onSubmit { commitWord() }

            if showingSnippetField {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                TextField("replacement", text: $snippetTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 180)
                    .foregroundStyle(Theme.text)
                    .themeField()
                    .onSubmit { commitSnippet() }
            }

            Button(showingSnippetField ? "Cancel" : "Snippet") {
                showingSnippetField.toggle()
                if !showingSnippetField { snippetTarget = "" }
            }
            .buttonStyle(ThemeButtonStyle())
        }
    }

    private func commitWord() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if showingSnippetField {
            commitSnippet()
            return
        }
        store.add(VocabEntry(source: trimmed, replacement: nil))
        input = ""
    }

    private func commitSnippet() {
        let src = input.trimmingCharacters(in: .whitespaces)
        let dst = snippetTarget.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty, !dst.isEmpty else { return }
        store.add(VocabEntry(source: src, replacement: dst))
        input = ""
        snippetTarget = ""
        showingSnippetField = false
    }
}

private struct VocabRow: View {
    let entry: VocabEntry
    @ObservedObject var store: VocabStore
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.source)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isSnippet, let replacement = entry.replacement {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                Text(replacement)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 120, alignment: .leading)
            }

            // Always in the layout, only its opacity changes. Inserting it on
            // hover reflowed the row (text shifted left, row grew taller).
            Button {
                store.remove(entry)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ThemeIconButtonStyle(size: 22, destructive: true))
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .help("Remove \(entry.source)")
            .accessibilityLabel("Remove \(entry.source)")
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(hovered ? Color.white.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Models

@MainActor
private final class ModelsViewModel: ObservableObject {
    @Published var downloadedIds: Set<String> = []
    @Published var inFlight: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var refreshing: Bool = false

    private let client = SidecarClient()

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let result = await client.listModels()
        if case .success(let list) = result {
            downloadedIds = Set(list.filter { $0.downloaded }.map { $0.id })
        }
    }

    func download(_ modelId: String) async {
        inFlight.insert(modelId)
        errors[modelId] = nil
        defer { inFlight.remove(modelId) }
        let result = await client.prefetch(modelId: modelId) { _ in
            // progress is indeterminate from huggingface_hub today;
            // we just keep "Downloading…" until it terminates.
        }
        switch result {
        case .success:
            downloadedIds.insert(modelId)
            DownloadedModelsCache.shared.refresh()
        case .failure(let err):
            errors[modelId] = "\(err)"
        }
    }

    func delete(_ modelId: String) async {
        errors[modelId] = nil
        let result = await client.deleteModel(modelId: modelId)
        switch result {
        case .success:
            downloadedIds.remove(modelId)
            DownloadedModelsCache.shared.refresh()
        case .failure(let err):
            errors[modelId] = "\(err)"
        }
    }
}

private struct ModelsSettingsPane: View {
    @AppStorage(UserModelSettings.activeModelIdKey) private var activeModelId: String = ModelRegistry.defaultModelId
    @StateObject private var vm = ModelsViewModel()

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 26) {
                header

                modelSection(
                    title: "English",
                    subtitle: "Fastest models here, and the most accurate on English. Use these if English is all you dictate.",
                    accent: Theme.Meta.english,
                    models: ModelRegistry.all.filter { !$0.multilingual }
                )

                modelSection(
                    title: "Multilingual",
                    subtitle: "Parakeet v3 covers 25 European languages and detects them on its own. Whisper covers 99, and picks from the languages you set under Languages.",
                    accent: Theme.Meta.multilingual,
                    models: ModelRegistry.all.filter { $0.multilingual }
                )
            }
        }
        .task { await vm.refresh() }
    }

    /// Restates the loaded model up top so the page answers "what am I using"
    /// before the reader scrolls into the catalog.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("OpenLark uses one model at a time. Download more to switch between them. The active one is loaded into memory, the rest sit on disk.")
                    .settingsHint()
            }

            HStack(spacing: 12) {
                MiniWaveform(height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("IN USE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                    Text(activeName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                }

                Spacer(minLength: 0)

                if !vm.downloadedIds.contains(activeModelId) {
                    ThemeChip(systemImage: "arrow.down.circle", text: "Not downloaded")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .themeCard(fill: Color.white.opacity(0.05))
        }
    }

    private var activeName: String {
        ModelRegistry.find(activeModelId)?.displayName ?? activeModelId
    }

    private func modelSection(
        title: String,
        subtitle: String,
        accent: Color,
        models: [ModelDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(accent.opacity(0.9))
                }
                Text(subtitle)
                    .settingsHint()
            }
            VStack(spacing: 8) {
                ForEach(models) { model in
                    ModelRow(
                        model: model,
                        isActive: activeModelId == model.id,
                        isDownloaded: vm.downloadedIds.contains(model.id),
                        isDownloading: vm.inFlight.contains(model.id),
                        error: vm.errors[model.id],
                        onSetActive: { activeModelId = model.id },
                        onDownload: {
                            Task { await vm.download(model.id) }
                        },
                        onDelete: {
                            Task { await vm.delete(model.id) }
                        }
                    )
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: ModelDescriptor
    let isActive: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let error: String?
    let onSetActive: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var hovered = false

    /// Only the model that is both selected and on disk is actually loaded.
    private var isLoaded: Bool { isActive && isDownloaded }

    /// Hue for the model's language family, repeated on the rail and the
    /// language chip so a glance down the page separates the two families.
    private var familyColor: Color {
        model.multilingual ? Theme.Meta.multilingual : Theme.Meta.english
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Family rail. The one visual that survives peripheral vision.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(familyColor.opacity(isLoaded ? 0.95 : 0.45))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)
                .padding(.trailing, 12)

            HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if isLoaded {
                        MiniWaveform(barCount: 7, height: 11)
                            .transition(.opacity)
                    }
                }

                Text(model.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ThemeChip(
                        systemImage: model.multilingual ? "globe" : "character",
                        text: model.multilingual ? "\(model.languageCount) languages" : "English only",
                        tint: familyColor
                    )
                    ThemeChip(
                        systemImage: "speedometer",
                        text: model.speedLabel,
                        tint: Theme.Meta.speed
                    )
                    ThemeChip(
                        systemImage: "internaldrive",
                        text: humanSize(mb: model.approxSizeMB),
                        tint: Theme.Meta.size
                    )
                    if isDownloaded {
                        ThemeChip(
                            systemImage: "checkmark",
                            text: "On disk",
                            tint: Theme.Meta.onDisk
                        )
                    }
                }
                .padding(.top, 1)

                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                actionControl

                // Kept in the layout at all times so hovering a row never
                // reflows it. Only opacity changes.
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ThemeIconButtonStyle(destructive: true))
                .opacity(isDownloaded && !isActive && hovered ? 1 : 0)
                .allowsHitTesting(isDownloaded && !isActive && hovered)
                .help("Delete this model, frees ~\(humanSize(mb: model.approxSizeMB))")
                .accessibilityLabel("Delete \(model.displayName)")
            }
            }
        }
        .padding(14)
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees about \(humanSize(mb: model.approxSizeMB)). You can re-download anytime.")
        }
        .themeCard(
            fill: isLoaded ? Color.white.opacity(0.07) : (hovered ? Theme.raisedHover : Theme.raised),
            border: isLoaded ? Theme.strokeStrong : Theme.stroke,
            borderWidth: isLoaded ? 1 : 0.5
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder
    private var actionControl: some View {
        if isDownloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(minWidth: 104, alignment: .trailing)
        } else if !isDownloaded {
            // Active-but-not-downloaded shouldn't happen for long: pressing
            // Download here makes the model usable; the daemon also auto-
            // loads the active model on first record.
            Button(action: onDownload) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Download")
                }
            }
            .buttonStyle(ThemeButtonStyle())
            .frame(minWidth: 104, alignment: .trailing)
        } else if !isActive {
            Button("Use", action: onSetActive)
                .buttonStyle(ThemeButtonStyle())
                .frame(minWidth: 104, alignment: .trailing)
        } else {
            Text("In use")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
                .frame(minWidth: 104, alignment: .trailing)
        }
    }

    private func humanSize(mb: Int) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024.0
            return String(format: "%.1f GB", gb)
        }
        return "\(mb) MB"
    }
}

// MARK: - Languages

private struct LanguagesSettingsPane: View {
    @State private var selected: Set<String> = Set(UserModelSettings.selectedLanguageCodes)
    @State private var search: String = ""

    private var filtered: [Language] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return LanguageCatalog.all }
        return LanguageCatalog.all.filter {
            $0.name.lowercased().contains(query)
                || $0.nativeName.lowercased().contains(query)
                || $0.code.lowercased().contains(query)
        }
    }

    private var selectedLanguages: [Language] {
        // Stable order by catalog index so chips don't jump around.
        LanguageCatalog.all.filter { selected.contains($0.code) }
    }

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !selectedLanguages.isEmpty {
                    selectedChips
                }

                allLanguages
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Languages I speak")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Applies to the Whisper models only. Pick one for the fastest, most accurate transcription, or pick a few to let Whisper detect which you are speaking. Parakeet v3 handles its 25 languages on its own and ignores this.")
                .settingsHint()
        }
    }

    private var selectedChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SELECTED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("\(selectedLanguages.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(selectedLanguages) { lang in
                    LanguageChip(name: lang.name) {
                        toggle(lang.code, on: false)
                    }
                }
            }
        }
    }

    private var allLanguages: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ALL LANGUAGES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                searchField
            }
            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, lang in
                    LanguageListRow(
                        lang: lang,
                        isOn: selected.contains(lang.code),
                        onToggle: { toggle(lang.code, on: !selected.contains(lang.code)) }
                    )
                    if idx < filtered.count - 1 {
                        Divider().opacity(0.07).padding(.leading, 44)
                    }
                }
                if filtered.isEmpty {
                    Text("No languages match \"\(search)\".")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 22)
                }
            }
            .themeCard()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 130)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .themeField(radius: 7)
    }

    private func toggle(_ code: String, on: Bool) {
        if on {
            selected.insert(code)
        } else {
            selected.remove(code)
        }
        // Always keep at least one. Fall back to English if empty, and put it
        // back into `selected` too. Writing only to defaults left the list
        // showing nothing selected while English was active, and the next
        // language picked then replaced English instead of joining it.
        if selected.isEmpty {
            selected = ["en"]
        }
        UserModelSettings.setSelectedLanguages(Array(selected))
    }
}

/// Wrap-to-next-line layout. Chips flow left-to-right, wrap when wide.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + spacing + s.width > maxWidth {
                totalHeight += lineHeight + lineSpacing
                maxLineWidth = max(maxLineWidth, lineWidth)
                lineWidth = s.width
                lineHeight = s.height
            } else {
                if lineWidth > 0 { lineWidth += spacing }
                lineWidth += s.width
                lineHeight = max(lineHeight, s.height)
            }
        }
        totalHeight += lineHeight
        maxLineWidth = max(maxLineWidth, lineWidth)
        return CGSize(width: maxLineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

private struct LanguageChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(ThemeIconButtonStyle(size: 16))
            .accessibilityLabel("Remove \(name)")
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
    }
}

private struct LanguageListRow: View {
    let lang: Language
    let isOn: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: isOn ? .regular : .light))
                    .foregroundStyle(isOn ? Theme.text : Theme.textTertiary)
                    .frame(width: 20)
                Text(lang.name)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? Theme.text : Theme.textSecondary)
                Text(lang.nativeName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(lang.code.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovered ? Color.white.opacity(0.045) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenLark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                    .settingsHint()
            }
            .padding(.bottom, 4)

            SettingsGroup(title: "Project") {
                LinkRow(label: "GitHub", url: "https://github.com/FabianGenell/openlark")
                LinkRow(label: "Report an issue", url: "https://github.com/FabianGenell/openlark/issues")
                LinkRow(label: "Releases", url: "https://github.com/FabianGenell/openlark/releases")
            }

            SettingsGroup(title: "License") {
                Text("MIT, free for personal and commercial use.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}

private struct LinkRow: View {
    let label: String
    let url: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
            Spacer()
            Button(action: {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }) {
                HStack(spacing: 4) {
                    Text(url.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Reusable

private struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
        }
    }
}

private extension View {
    func settingsHint() -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
