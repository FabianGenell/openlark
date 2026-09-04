import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Lets callers outside the SwiftUI tree pick which section Settings shows,
/// including when the window is already open.
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var section: SettingsSection = .general
    /// Anchor to scroll to once the section is showing. Cleared after the jump
    /// so returning to the page later starts at the top as usual.
    @Published var scrollTarget: String?

    func go(_ section: SettingsSection, to anchor: String? = nil) {
        self.section = section
        scrollTarget = anchor
    }
}

enum SettingsWindowFactory {
    @MainActor
    static func make(navigator: SettingsNavigator) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // An opaque titlebar, not a transparent one over full-size content.
        // With fullSizeContentView the scroll view ran under the title, so
        // rows slid behind the word "Settings" and collided with it.
        window.titlebarAppearsTransparent = false
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
    case polish = "Polish"
    case models = "Models"
    case languages = "Languages"
    case about = "About"

    var id: String { rawValue }

    /// Hue for the row's glyph while the section is selected. Unselected rows
    /// stay grey like every other one; only the selected Polish row is pink,
    /// echoing the sparkle on the recording pill.
    var selectedTint: Color? {
        self == .polish ? Theme.Meta.polish : nil
    }

    var icon: String {
        switch self {
        case .general: return "gauge.medium"
        case .vocabulary: return "text.book.closed"
        case .polish: return "sparkle"
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
        case .polish:
            PolishSettingsPane(navigator: navigator, store: PolishProfileStore.shared)
        case .models:
            ModelsSettingsPane(navigator: navigator)
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

    /// Only the glyph takes the section's hue, never the label, so the row still
    /// reads as one of a set.
    private var iconTint: Color {
        guard isSelected else { return Theme.textSecondary }
        return section.selectedTint ?? Theme.text
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Weight stays put across states. Bolding the selected row
                // reflows it a hair wider and the whole sidebar twitches as you
                // move between pages; colour alone carries the selection.
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(iconTint)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .regular))
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

            SettingsGroup(title: "Hotkey") {
                HStack {
                    Text("Toggle recording")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleRecording)
                }
            }

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
            }

        }
    }

}

// MARK: - Polish

private struct PolishSettingsPane: View {
    @ObservedObject var navigator: SettingsNavigator
    @ObservedObject var store: PolishProfileStore
    @AppStorage(PolishSettings.polishByDefaultKey) private var polishOn: Bool = false
    /// One row open at a time, so the page stays a list rather than growing
    /// into a wall of editors.
    @State private var expandedId: UUID?
    /// A row that should take the caret as soon as it appears, so "New" lands
    /// you typing the name instead of hunting for the field.
    @State private var focusNameId: UUID?

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 22) {
                header

                Toggle("Polish transcriptions", isOn: $polishOn)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()

                profilesSection
                PolishPillHint()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Polish")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Tidies a dictation before it lands: filler, repeated words, punctuation, paragraphs.")
                .settingsHint()
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROFILES")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    let created = store.add()
                    expandedId = created.id
                    focusNameId = created.id
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("New")
                    }
                }
                .buttonStyle(ThemeButtonStyle())
            }

            VStack(spacing: 0) {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { idx, profile in
                    PolishProfileRow(
                        profile: profile,
                        isActive: profile.id == store.active?.id,
                        isExpanded: expandedId == profile.id,
                        canDelete: store.profiles.count > 1,
                        onUse: { store.setActive(profile) },
                        onToggleExpanded: {
                            expandedId = expandedId == profile.id ? nil : profile.id
                        },
                        onChange: { store.update($0) },
                        autofocusName: focusNameId == profile.id,
                        onAutofocusHandled: { focusNameId = nil },
                        onDelete: {
                            if expandedId == profile.id { expandedId = nil }
                            store.remove(profile)
                        },
                        onChooseModel: { navigator.go(.models, to: ModelsSettingsPane.polishAnchor) }
                    )
                    if idx < store.profiles.count - 1 {
                        Divider().opacity(0.07).padding(.leading, 40)
                    }
                }
            }
            .themeCard()
        }
    }
}

/// One profile, collapsed to a line and expanded to its own editor in place.
/// The row is the profile: there is no second panel elsewhere on the page that
/// has to be kept in sync with whichever line is highlighted.
private struct PolishProfileRow: View {
    let profile: PolishProfile
    let isActive: Bool
    let isExpanded: Bool
    let canDelete: Bool
    let onUse: () -> Void
    let onToggleExpanded: () -> Void
    let onChange: (PolishProfile) -> Void
    let autofocusName: Bool
    let onAutofocusHandled: () -> Void
    let onDelete: () -> Void
    let onChooseModel: () -> Void

    @State private var hovered = false
    @State private var draft: PolishProfile
    @FocusState private var nameFocused: Bool
    @State private var showDeleteConfirm = false
    @State private var editingName = false
    @State private var showAdvanced = false
    @State private var advancedHovered = false
    @ObservedObject private var downloaded = DownloadedModelsCache.shared

    init(
        profile: PolishProfile,
        isActive: Bool,
        isExpanded: Bool,
        canDelete: Bool,
        onUse: @escaping () -> Void,
        onToggleExpanded: @escaping () -> Void,
        onChange: @escaping (PolishProfile) -> Void,
        autofocusName: Bool,
        onAutofocusHandled: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onChooseModel: @escaping () -> Void
    ) {
        self.profile = profile
        self.isActive = isActive
        self.isExpanded = isExpanded
        self.canDelete = canDelete
        self.onUse = onUse
        self.onToggleExpanded = onToggleExpanded
        self.onChange = onChange
        self.autofocusName = autofocusName
        self.onAutofocusHandled = onAutofocusHandled
        self.onDelete = onDelete
        self.onChooseModel = onChooseModel
        _draft = State(initialValue: profile)
    }

    private var subtitle: String {
        let instruction = draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = PolishRegistry.find(draft.modelId)?.displayName
        let temp = draft.temperature > 0 ? String(format: "temp %.2f", draft.temperature) : nil
        return [instruction.isEmpty ? nil : instruction, model, temp]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    private var resolvedModelId: String { draft.modelId }

    private var modelLabel: String {
        PolishRegistry.find(resolvedModelId)?.displayName ?? resolvedModelId
    }

    private var modelDetail: String? { nil }

    /// Pinning a model that isn't on disk falls back silently at dictation
    /// time, so the control says where it stands instead.
    private var modelNote: String? {
        if downloaded.isDownloading(resolvedModelId) { return "Downloading…" }
        if downloaded.errors[resolvedModelId] != nil { return "Download failed" }
        return downloaded.downloadedIds.contains(resolvedModelId) ? nil : "Not downloaded"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                editor
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(rowFill)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onChange(of: draft) { _, new in onChange(new) }
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var rowFill: Color {
        if isExpanded { return Color.white.opacity(0.035) }
        return hovered ? Color.white.opacity(0.045) : .clear
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Separate from the row's own click target: choosing which profile
            // runs and opening it to edit are different intentions.
            Button(action: onUse) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? Theme.text : Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? "\(profile.name) is in use" : "Use \(profile.name)")
            .accessibilityLabel(isActive ? "\(profile.name) is in use" : "Use \(profile.name)")

            VStack(alignment: .leading, spacing: 2) {
                if isExpanded && editingName {
                    // The heading is the name field while you're renaming.
                    // Writing the name twice, once as a heading and again in a
                    // labelled box below, made the row look like two things.
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .focused($nameFocused)
                        .onSubmit { editingName = false }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Theme.strokeStrong, lineWidth: 0.5)
                        )
                        .frame(maxWidth: 240, alignment: .leading)
                        .padding(.leading, -6)
                        .onChange(of: nameFocused) { _, focused in
                            // Clicking away commits, same as pressing return.
                            if !focused { editingName = false }
                        }
                } else {
                    HStack(spacing: 4) {
                        Text(draft.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)

                        if isExpanded {
                            Button {
                                editingName = true
                                DispatchQueue.main.async { nameFocused = true }
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .buttonStyle(ThemeIconButtonStyle(size: 20))
                            .help("Rename \(profile.name)")
                            .accessibilityLabel("Rename \(profile.name)")
                        }
                    }
                    if !isExpanded && !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        // The whole row is the target, not just the chevron. The radio and the
        // rename button are real Buttons, so they take their own clicks first;
        // while renaming the gesture is off entirely so it can't steal focus
        // from the field.
        .onTapGesture {
            guard !editingName else { return }
            onToggleExpanded()
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Special polish instructions")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                // A vertical TextField, not a TextEditor. TextEditor is a
                // scroll view: it shows a scroller at a fixed height whether or
                // not there is anything to scroll, and it has no placeholder,
                // so the fake one had to be positioned by hand and never sat on
                // the same baseline as the caret. This has a real placeholder
                // and grows with the text instead of scrolling inside itself.
                // No upper line limit: the field grows to fit whatever is in
                // it, so a long instruction is read in full and the Settings
                // page does the scrolling. Capping it meant a prompt of any
                // real length was clipped with no way to scroll or resize.
                TextField("Keep it formal.", text: $draft.instruction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .themeField()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                ThemeDropdown(
                    value: modelLabel,
                    detail: modelDetail,
                    note: modelNote
                ) {
                    modelMenuItems
                }
                .frame(maxWidth: 320)
            }

            advanced

            if canDelete {
                HStack {
                    Spacer()
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Delete")
                        }
                    }
                    .buttonStyle(ThemeButtonStyle())
                    .help("Delete \(profile.name)")
                }
            }
        }
        .padding(.leading, 30)
        .onAppear {
            DownloadedModelsCache.shared.refresh()
            guard autofocusName else { return }
            editingName = true
            // The field is created in the same layout pass; focusing it has to
            // wait for that pass to finish or the caret lands nowhere.
            DispatchQueue.main.async {
                nameFocused = true
                onAutofocusHandled()
            }
        }
    }

    /// Everything a profile can be tuned with that most profiles never need.
    /// Collapsed by default so the common case stays three fields.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Advanced")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(advancedHovered ? Theme.textSecondary : Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { advancedHovered = $0 }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperature")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f", draft.temperature))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }

                    Slider(value: $draft.temperature, in: 0...1, step: 0.05)
                        .controlSize(.small)

                    HStack {
                        Text("Same every time")
                        Spacer()
                        Text("Freer wording")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
                .padding(12)
                .themeCard(fill: Color.white.opacity(0.03))
            }
        }
        .animation(.easeOut(duration: 0.14), value: showAdvanced)
    }

    private var modelMenuItems: [PopupMenuItem] {
        var items: [PopupMenuItem] = []
        for model in PolishRegistry.all {
            let onDisk = downloaded.downloadedIds.contains(model.id)
            let busy = downloaded.isDownloading(model.id)
            items.append(PopupMenuItem(
                title: model.displayName,
                subtitle: busy ? "downloading…"
                    : (onDisk ? humanSize(mb: model.approxSizeMB)
                              : "download " + humanSize(mb: model.approxSizeMB)),
                isOn: draft.modelId == model.id,
                action: { select(model.id) }
            ))
        }
        items.append(.separator)
        items.append(PopupMenuItem(title: "Manage models…", action: onChooseModel))
        return items
    }

    /// Choosing a model that isn't on disk starts fetching it there and then.
    /// Making the choice and then having to find the same model again in the
    /// catalog to download it is two steps for one intention, and a profile
    /// pointing at a missing model silently falls back at dictation time.
    private func select(_ modelId: String) {
        draft.modelId = modelId
        guard !downloaded.downloadedIds.contains(modelId) else { return }
        Task { await DownloadedModelsCache.shared.download(modelId) }
    }

    private func humanSize(mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024.0) : "\(mb) MB"
    }
}

/// A drawn copy of the recording pill with a cursor resting on its glyph, for
/// the one thing nothing else announces: that the glyph is a button.
///
/// Drawn rather than shipped as a PNG. It reuses the overlay's own `WaveformBars`
/// and `KeyCap` at the overlay's own metrics, so it cannot drift out of date with
/// the real pill, it stays sharp at any scale factor, and it costs the bundle
/// nothing.
private struct PolishPillHint: View {
    @AppStorage("polishHintExpanded") private var expanded: Bool = false
    @State private var headerHovered = false

    /// A still frame of a real-looking utterance. Fixed rather than random, so
    /// the picture is identical every time the pane opens.
    private static let levels: [Float] = (0..<72).map { i in
        let p = Double(i) / 71.0
        let envelope = pow(sin(p * .pi), 0.55)
        return Float(envelope * (0.28 + 0.72 * abs(sin(p * 23) * cos(p * 9))))
    }

    // The overlay's own metrics, so the drawing is the pill and not an
    // approximation of it. See OverlayView.
    private static let waveHeight: CGFloat = 52
    private static let waveTopPad: CGFloat = 10
    private static let barVPad: CGFloat = 9
    private static let barContentHeight: CGFloat = 16
    private static let barHPad: CGFloat = 14
    private static let glyphWidth: CGFloat = 14

    /// Where the cursor's tip has to land: the bar's padding plus half the
    /// glyph across, and the middle of the bar down.
    private static var glyphCenter: CGPoint {
        CGPoint(
            x: barHPad + glyphWidth / 2,
            y: waveTopPad + waveHeight + barVPad + barContentHeight / 2
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    pill
                    Text("The glyph is a button. Click it to switch polish on and off without stopping the recording.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            }
        }
        .padding(14)
        .themeCard(fill: Color.white.opacity(0.03))
        .animation(.easeOut(duration: 0.16), value: expanded)
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(headerHovered ? Theme.textSecondary : Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Switching it while you record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(headerHovered ? Theme.text : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: headerHovered)
        .accessibilityLabel(expanded ? "Hide the recording pill example" : "Show the recording pill example")
    }

    private var pill: some View {
        VStack(spacing: 0) {
            WaveformBars(levels: Self.levels)
                .frame(height: Self.waveHeight)
                .padding(.horizontal, 20)
                .padding(.top, Self.waveTopPad)

            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Meta.polish)
                    .frame(width: Self.glyphWidth, height: Self.barContentHeight)

                Text("Voice")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer(minLength: 0)

                Text("Stop")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                KeyCap(symbol: "command")
                KeyCap(symbol: "arrow.up")
            }
            .padding(.horizontal, Self.barHPad)
            .padding(.vertical, Self.barVPad)
            .background(Color.black.opacity(0.55))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
            }
        }
        .background(Color.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
        // Outside the clip, so the pointer can hang past the pill's edge the
        // way a real one does.
        .overlay(alignment: .topLeading) {
            MacPointer()
                .offset(x: Self.glyphCenter.x + 1, y: Self.glyphCenter.y + 1)
        }
    }
}

/// The macOS arrow pointer, drawn to the system shape: white body, dark
/// outline, soft drop shadow, hotspot at the very tip. Positioned by its tip,
/// so callers place it at the point it should be pointing at.
private struct MacPointer: View {
    var height: CGFloat = 21

    private var width: CGFloat { height * (12.0 / 19.0) }

    var body: some View {
        PointerShape()
            .fill(.white)
            .overlay(
                PointerShape()
                    .stroke(Color.black.opacity(0.85), lineWidth: 1)
            )
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0.5, y: 1.5)
    }

    private struct PointerShape: Shape {
        func path(in rect: CGRect) -> Path {
            // The classic pointer, in a 12 × 19 box with the tip at the origin.
            let pts: [CGPoint] = [
                CGPoint(x: 0.0,  y: 0.0),
                CGPoint(x: 0.0,  y: 16.4),
                CGPoint(x: 3.7,  y: 12.9),
                CGPoint(x: 5.9,  y: 18.7),
                CGPoint(x: 8.0,  y: 17.8),
                CGPoint(x: 5.8,  y: 12.2),
                CGPoint(x: 10.2, y: 12.0),
            ]
            let sx = rect.width / 12.0
            let sy = rect.height / 19.0
            var path = Path()
            for (i, p) in pts.enumerated() {
                let scaled = CGPoint(x: rect.minX + p.x * sx, y: rect.minY + p.y * sy)
                if i == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
            }
            path.closeSubpath()
            return path
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

private struct PolishModelRow: View {
    /// One width for every state of the action column, so Download, Use and
    /// In use are the same size and the column reads as a column.
    static let actionWidth: CGFloat = 112

    let model: PolishModelDescriptor
    let usedByProfiles: Int
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double?
    let etaSeconds: Double?
    let onDiskMB: Int
    let error: String?
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var hovered = false

    /// Anything on disk is deletable, finished or not. Gating this on a
    /// completed download stranded interrupted attempts with no way to reclaim
    /// the space.
    private var hasBytesOnDisk: Bool { isDownloaded || onDiskMB > 0 }

    private var isLoaded: Bool { isDownloaded && usedByProfiles > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.Meta.polish.opacity(isLoaded ? 0.95 : 0.45))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)
                .padding(.trailing, 12)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)

                    Text(model.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
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
                        if usedByProfiles > 0 {
                            ThemeChip(
                                systemImage: "sparkle",
                                text: usedByProfiles == 1 ? "1 profile" : "\(usedByProfiles) profiles",
                                tint: Theme.Meta.polish
                            )
                        }
                    }
                    .padding(.top, 1)

                    if !isDownloaded && onDiskMB > 0 {
                        PartialDownloadBar(
                            onDiskMB: onDiskMB,
                            totalMB: model.approxSizeMB,
                            live: progress
                        )
                    }

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
                        .frame(width: Self.actionWidth)

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(ThemeIconButtonStyle(destructive: true))
                    .opacity(hasBytesOnDisk && hovered ? 1 : 0)
                    .allowsHitTesting(hasBytesOnDisk && hovered)
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
            if !isDownloaded {
                Text("Removes \(humanSize(mb: onDiskMB)) of a download that never finished.")
            } else if usedByProfiles > 0 {
                Text("\(usedByProfiles == 1 ? "A profile uses" : "\(usedByProfiles) profiles use") this model and will stop polishing until it's downloaded again. Frees about \(humanSize(mb: model.approxSizeMB)).")
            } else {
                Text("Frees about \(humanSize(mb: model.approxSizeMB)). You can re-download anytime.")
            }
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
            DownloadProgress(progress: progress, etaSeconds: etaSeconds)
        } else if !isDownloaded {
            Button(action: onDownload) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Download")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemeButtonStyle())
        } else {
            // Downloaded polish models have no action; the column still holds
            // its width so the buttons above and below line up with it.
            Color.clear.frame(height: 26)
        }
    }

    private func humanSize(mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    /// Anchor the General pane's "Model" row jumps to.
    static let polishAnchor = "polish-models"

    @ObservedObject var navigator: SettingsNavigator
    @AppStorage(UserModelSettings.activeModelIdKey) private var activeModelId: String = ModelRegistry.defaultModelId
    @ObservedObject private var vm = DownloadedModelsCache.shared

    var body: some View {
        ScrollViewReader { proxy in
            SettingsScroll {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    modelSection(
                        title: "English",
                        subtitle: "The fastest models, and the most accurate on English. Use these if English is all you dictate.",
                        accent: Theme.Meta.english,
                        models: ModelRegistry.all.filter { !$0.multilingual }
                    )

                    modelSection(
                        title: "Multilingual",
                        subtitle: "Parakeet v3 covers 25 European languages and detects them on its own. Whisper covers 99, and picks from the languages you set under Languages.",
                        accent: Theme.Meta.multilingual,
                        models: ModelRegistry.all.filter { $0.multilingual }
                    )

                    polishSection
                        .id(Self.polishAnchor)
                }
            }
            .onAppear { jump(proxy) }
            .onChange(of: navigator.scrollTarget) { _, _ in jump(proxy) }
        }
        .task { await vm.refreshNow() }
    }

    /// Consumes the pending anchor, so coming back to this page later opens at
    /// the top rather than replaying the last jump.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let target = navigator.scrollTarget else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
            navigator.scrollTarget = nil
        }
    }

    /// Restates the loaded model up top so the page answers "what am I using"
    /// before the reader scrolls into the catalog.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("OpenLark uses one speech model at a time, plus a polish model if you want one. Download more to switch between them. The active ones are loaded into memory, the rest sit on disk.")
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
                        progress: vm.progress[model.id],
                        etaSeconds: vm.etaSeconds[model.id],
                        onDiskMB: vm.onDiskMB[model.id] ?? 0,
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

private extension ModelsSettingsPane {
    /// Polish uses a language model rather than a speech model, so it sits in
    /// its own group with its own hue. There is nothing to "use" here: each
    /// polish profile names its own model, so this list only downloads and
    /// deletes them.
    var polishSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.Meta.polish)
                        .frame(width: 6, height: 6)
                    Text("POLISH")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.Meta.polish.opacity(0.9))
                }
                Text("Cleans up a finished transcript. Each profile under Polish picks the one it wants.")
                    .settingsHint()
            }
            VStack(spacing: 8) {
                ForEach(PolishRegistry.all) { model in
                    PolishModelRow(
                        model: model,
                        usedByProfiles: PolishProfileStore.shared.profileCount(usingModel: model.id),
                        isDownloaded: vm.downloadedIds.contains(model.id),
                        isDownloading: vm.inFlight.contains(model.id),
                        progress: vm.progress[model.id],
                        etaSeconds: vm.etaSeconds[model.id],
                        onDiskMB: vm.onDiskMB[model.id] ?? 0,
                        error: vm.errors[model.id],
                        onDownload: { Task { await vm.download(model.id) } },
                        onDelete: { Task { await vm.delete(model.id) } }
                    )
                }
            }
        }
    }
}

private struct ModelRow: View {
    /// One width for every state of the action column, so Download, Use and
    /// In use are the same size and the column reads as a column.
    static let actionWidth: CGFloat = 112

    let model: ModelDescriptor
    let isActive: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double?
    let etaSeconds: Double?
    let onDiskMB: Int
    let error: String?
    let onSetActive: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var hovered = false

    /// Anything on disk is deletable, finished or not. Gating this on a
    /// completed download stranded interrupted attempts with no way to reclaim
    /// the space.
    private var hasBytesOnDisk: Bool { isDownloaded || onDiskMB > 0 }

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

                if !isDownloaded && onDiskMB > 0 {
                    PartialDownloadBar(
                        onDiskMB: onDiskMB,
                        totalMB: model.approxSizeMB,
                        live: progress
                    )
                }

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
                    .frame(width: Self.actionWidth)

                // Kept in the layout at all times so hovering a row never
                // reflows it. Only opacity changes.
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ThemeIconButtonStyle(destructive: true))
                .opacity(hasBytesOnDisk && !isActive && hovered ? 1 : 0)
                .allowsHitTesting(hasBytesOnDisk && !isActive && hovered)
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
            if !isDownloaded {
                Text("Removes \(humanSize(mb: onDiskMB)) of a download that never finished.")
            } else {
                Text("Frees about \(humanSize(mb: model.approxSizeMB)). You can re-download anytime.")
            }
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
            DownloadProgress(progress: progress, etaSeconds: etaSeconds)
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
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemeButtonStyle())
        } else if !isActive {
            Button(action: onSetActive) {
                Text("Use").frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemeButtonStyle())
        } else {
            // Same font, padding and corner as ThemeButtonStyle. It was a
            // capsule with its own metrics, so it sat at a different height and
            // width from the Download button on the row above and the column
            // looked ragged.
            Text("In use")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
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

/// Percentage plus a bar, measured from bytes on disk. A spinner alone can't
/// tell a running download from a dead one, which is how a download killed by a
/// daemon restart sat there looking busy.
/// How much of a model is on disk, as a bar under its chips. A wrapping
/// "586 MB so far" chip said the same thing in two ragged lines and gave no
/// sense of how much was left to go.
private struct PartialDownloadBar: View {
    let onDiskMB: Int
    let totalMB: Int
    /// Live fraction while a download is actually running. Nil means the bytes
    /// on disk are leftovers from an interrupted attempt.
    let live: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let live {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(Theme.Meta.size.opacity(0.85))
                            .frame(width: max(2, geo.size.width * min(1, max(0, live))))
                    }
                }
                .frame(height: 3)

                // Derived from the same fraction as the bar. Reading onDiskMB
                // here showed a stale figure from the last models refresh
                // beside a live percentage, and the two disagreed.
                Text("\(size(Int(live * Double(totalMB)))) of \(size(totalMB))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            } else {
                // Deliberately not framed as progress. An interrupted download
                // does not pick up where it left off: measured, a 603 MB partial
                // blob was truncated and refetched from zero on the next
                // attempt. Calling it "586 MB of 4.0 GB" next to a Resume button
                // promised something that doesn't happen. It's disk being used,
                // and the useful thing to offer is a way to reclaim it.
                Text("\(size(onDiskMB)) left over from an interrupted download")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 3)
    }

    private func size(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024.0) : "\(mb) MB"
    }
}

private struct DownloadProgress: View {
    let progress: Double?
    let etaSeconds: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            if let remaining {
                Text(remaining)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var label: String {
        guard let progress else { return "Starting…" }
        return "Downloading \(Int(progress * 100))%"
    }

    /// Deliberately coarse. The estimate is built from a one-minute window on a
    /// connection that varies, so a figure like "7 min 12 sec" would claim a
    /// precision it doesn't have and visibly jitter.
    private var remaining: String? {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0 else { return nil }
        if etaSeconds < 45 { return "less than a minute" }
        let minutes = Int((etaSeconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = Double(minutes) / 60
        return "about \(String(format: "%.1f", hours)) hr left"
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
    /// Optional glyph on the group label, in its own hue. Only Polish uses one,
    /// carrying the same sparkle and colour as the recording pill so the two
    /// read as one feature across the app.
    var icon: String? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint ?? Theme.textTertiary)
                }
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(tint ?? Theme.textTertiary)
            }
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
