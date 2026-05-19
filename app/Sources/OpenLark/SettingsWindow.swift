import AppKit
import SwiftUI

enum SettingsWindowFactory {
    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Vocabulary"
        window.isReleasedWhenClosed = false
        window.center()

        let view = NSHostingView(rootView: VocabSettingsView(store: VocabStore.shared))
        window.contentView = view
        return window
    }
}

struct VocabSettingsView: View {
    @ObservedObject var store: VocabStore
    @State private var input: String = ""
    @State private var snippetTarget: String = ""
    @State private var showingSnippetField: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.15)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.entries) { entry in
                        VocabRow(entry: entry, store: store)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inputRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Add a word or create a snippet", text: $input)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
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
                        .padding(.vertical, 10)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hovered ? Color.white.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
