import AppKit
import ServiceManagement
import SwiftUI

enum SettingsWindowFactory {
    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let view = NSHostingView(rootView: SettingsRoot())
        window.contentView = view
        return window
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case vocabulary = "Vocabulary"
    case models = "Models"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gauge.medium"
        case .vocabulary: return "text.book.closed"
        case .models: return "cpu"
        case .about: return "info.circle"
        }
    }
}

/// Manual sidebar+detail layout. NavigationSplitView inside a manually-hosted
/// NSWindow doesn't render reliably (sidebar items can vanish, detail can show
/// transparent), so we hand-roll the split.
struct SettingsRoot: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider().opacity(0.18)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 740, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(section.rawValue)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == section ? Color.white.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.primary : Color.secondary)
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
        case .about:
            AboutSettingsPane()
        }
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
                    HStack(spacing: 4) {
                        keyCap("command")
                        keyCap("arrow.up")
                    }
                }
                Text("Hotkey customization is coming in a future release.")
                    .settingsHint()
            }
        }
    }

    private func keyCap(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.10))
            )
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
                        .foregroundStyle(.tertiary)
                    Text("No custom vocabulary yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .onSubmit { commitWord() }

            if showingSnippetField {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

                TextField("replacement", text: $snippetTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .onSubmit { commitSnippet() }
            }

            Button(showingSnippetField ? "Cancel" : "Snippet") {
                showingSnippetField.toggle()
                if !showingSnippetField { snippetTarget = "" }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isSnippet, let replacement = entry.replacement {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                Text(replacement)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 120, alignment: .leading)
            }

            if hovered {
                Button {
                    store.remove(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(0.8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(hovered ? Color.white.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "Speech model") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Parakeet TDT 0.6B v2")
                            .font(.system(size: 14, weight: .medium))
                        Text("NVIDIA · MLX · English-only · ~25× realtime")
                            .settingsHint()
                    }
                    Spacer()
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.04))
                )
                Text("Multilingual support via mlx-whisper and per-language model switching is on the roadmap.")
                    .settingsHint()
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenLark")
                    .font(.system(size: 28, weight: .semibold))
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
                Text("MIT — free for personal and commercial use.")
                    .font(.system(size: 13))
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
                .foregroundStyle(.secondary)
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
                .tracking(0.5)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

private extension View {
    func settingsHint() -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
