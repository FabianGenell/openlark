import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var statusLabel: String {
        switch model.phase {
        case .listening: return "Voice"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        }
    }

    /// While listening with polish on, the word is replaced by the profile
    /// picker: which profile is about to run is the useful thing to say there,
    /// and it's the fastest place to change your mind. The two swap with a
    /// spring so the bar reads as one control changing shape rather than two
    /// controls appearing and disappearing.
    @ViewBuilder
    private var label: some View {
        if model.phase == .listening && model.polishOn && model.polishReady && !model.profileNames.isEmpty {
            ProfilePicker(
                names: model.profileNames,
                active: model.activeProfile,
                onSelect: { model.onSelectProfile?($0) },
                hostWindow: model.hostWindow
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                removal: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity)
            ))
        } else {
            Text(statusLabel)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity)
                ))
        }
    }

    /// Only the controls that do something in the current phase. The keycaps
    /// used to stay on screen through transcription with their labels blanked,
    /// advertising shortcuts that did nothing.
    ///
    /// Split out of the bar's HStack because the compiler could not type-check
    /// the whole row once it carried conditionals.
    @ViewBuilder
    private var trailingControls: some View {
        if model.phase == .listening {
            Text("Stop")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            KeyCap(symbol: "command")
            KeyCap(symbol: "arrow.up")
        }

        if model.phase == .polishing {
            SkipPolishButton { model.onSkipPolish?() }
        }

        Text("Cancel")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.leading, model.phase == .listening ? 6 : 0)

        KeyCap(text: "esc")
    }

    var body: some View {
        VStack(spacing: 0) {
            // While polishing, the same bars carry the progress: everything up
            // to the fraction takes the polish hue, the rest stays grey. It
            // reuses the one element already on the pill instead of adding a
            // second bar under it.
            WaveformBars(
                levels: model.levels,
                progress: model.phase == .polishing ? model.polishProgress : nil
            )
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            HStack(spacing: 10) {
                PolishToggle(isOn: model.polishOn, isReady: model.polishReady) {
                    model.onTogglePolish?()
                }

                label

                Spacer()

                trailingControls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.polishOn)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.phase)
            .background(Color.black.opacity(0.55))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Shadow OUTSIDE the clipShape so it follows the rounded silhouette
        // rather than being cropped to the same rounded rect.
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 5)
        .padding(20)
    }
}

/// The mic glyph, doubling as the polish switch.
///
/// One glyph swaps for the other: a mic while polish is off, a sparkle in the
/// polish hue while it's on. Nothing is layered, nothing is framed, and both
/// symbols occupy the same 12pt box, so the row never shifts and the glyph
/// stays where the eye already expects it.
///
/// Hover is a brightness lift rather than a background. A plate behind an icon
/// this small reads as a second object and pads the bar out; the lift still
/// says "pressable" and draws nothing at rest.
private struct PolishToggle: View {
    let isOn: Bool
    let isReady: Bool
    let action: () -> Void

    @State private var hovered = false

    private var armed: Bool { isOn && isReady }

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "sparkle" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .animation(.easeOut(duration: 0.12), value: isReady)
        .help(helpText)
        .accessibilityLabel(isOn ? "Turn polish off" : "Turn polish on")
    }

    private var helpText: String {
        if !isOn { return "Polish is off. Click to turn it on." }
        if !isReady { return "This profile's polish model isn't downloaded yet, so this dictation won't be polished." }
        return "Polish is on. Click to turn it off."
    }

    /// Switched on without a model is drawn in the plain text ramp, not the
    /// polish hue. The colour is the promise that polish will run.
    private var tint: Color {
        if armed {
            return hovered ? Theme.Meta.polish : Theme.Meta.polish.opacity(0.88)
        }
        return .white.opacity(hovered ? 1 : (isOn ? 0.5 : 0.85))
    }
}

/// Takes the transcript as dictated and abandons the polish.
///
/// By the time this is on screen the raw transcript already exists - polish is
/// a second pass over text the speech model has already produced - so this is
/// just a matter of taking it. Useful when polish was on by accident and the
/// wait is pure cost.
private struct SkipPolishButton: View {
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Use original")
                    .font(.system(size: 12, weight: .medium))
                KeyCap(text: "tab")
            }
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(hovered ? 0.12 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(hovered ? 0.3 : 0.18), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Tab. Paste the transcript as dictated, without waiting for polish.")
        .accessibilityLabel("Use the original transcript")
    }
}

/// The profile dropdown that stands in for the status word while polish is
/// armed.
///
/// A plain button over `PopupMenu`, rather than a SwiftUI `Menu`; see
/// MenuPopup.swift for why every macOS menu style was unusable here.
private struct ProfilePicker: View {
    let names: [String]
    let active: String
    let onSelect: (Int) -> Void
    let hostWindow: (() -> NSWindow?)?

    @State private var hovered = false

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 5) {
                Text(active)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            // No plate at rest, light or dark: an outline alone is enough to
            // say "control" on a surface this dark, and any fill reads as a
            // second panel sitting on the bar. The fill only shows on hover.
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(hovered ? 0.10 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.28 : 0.16), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Polish profile")
        .accessibilityLabel("Polish profile: \(active)")
    }

    private func popUp() {
        PopupMenu.show(
            names.enumerated().map { index, name in
                PopupMenuItem(
                    title: name,
                    isOn: name == active,
                    action: { onSelect(index) }
                )
            },
            over: hostWindow?()
        )
    }
}

struct WaveformBars: View {
    let levels: [Float]
    /// 0...1 to colour the leading bars, nil to leave every bar plain.
    var progress: Double? = nil

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let h = max(2, CGFloat(level) * geo.size.height)
                    let opacity = 0.35 + 0.65 * Double(level)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fill(at: index, opacity: opacity))
                        .frame(width: 3, height: h)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.25), value: progress)
        }
    }

    private func fill(at index: Int, opacity: Double) -> Color {
        guard let progress else { return .white.opacity(opacity) }
        let position = Double(index) / Double(max(1, levels.count - 1))
        return position <= progress
            ? Theme.Meta.polish.opacity(0.55 + 0.45 * opacity)
            : .white.opacity(opacity * 0.45)
    }
}

struct KeyCap: View {
    var symbol: String? = nil
    var text: String? = nil

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            } else if let text {
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(minWidth: 18, minHeight: 18)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.12))
        )
    }
}
