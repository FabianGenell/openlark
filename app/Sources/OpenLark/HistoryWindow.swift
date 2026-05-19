import AppKit
import SwiftUI

enum HistoryWindowFactory {
    @MainActor
    static func make(injector: TextInjector) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.center()

        let view = NSHostingView(rootView: HistoryView(store: HistoryStore.shared, injector: injector))
        window.contentView = view
        return window
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let injector: TextInjector
    @State private var search: String = ""
    @State private var copiedID: UUID?

    private var filtered: [TranscriptEntry] {
        guard !search.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.text.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.15)

            if filtered.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            HistoryRow(
                                entry: entry,
                                isCopied: copiedID == entry.id,
                                onCopy: { copy(entry) },
                                onPaste: { paste(entry) },
                                onDelete: { store.remove(entry) }
                            )
                            if entry.id != filtered.last?.id {
                                Divider().opacity(0.06).padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search transcriptions", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            Spacer()

            Text("\(store.entries.count) / \(HistoryStore.maxEntries)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if !store.entries.isEmpty {
                Button("Clear") {
                    store.clear()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No transcriptions yet" : "No matches")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if search.isEmpty {
                Text("Press ⌘+↑ in any text field to dictate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private func copy(_ entry: TranscriptEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func paste(_ entry: TranscriptEntry) {
        // Hide the history window so the previously focused app receives the paste.
        NSApp.keyWindow?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            injector.inject(text: entry.text)
        }
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(formatTimestamp(entry.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1fs", entry.durationSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if hovered {
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovered ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton(symbol: isCopied ? "checkmark" : "doc.on.doc", help: "Copy") {
                onCopy()
            }
            iconButton(symbol: "arrow.up.right.square", help: "Paste into focused app") {
                onPaste()
            }
            iconButton(symbol: "xmark", help: "Delete") {
                onDelete()
            }
        }
    }

    private func iconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            formatter.timeStyle = .short
            return "Yesterday, \(formatter.string(from: date))"
        }
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
