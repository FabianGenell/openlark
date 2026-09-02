import SwiftUI

/// The visual language borrowed from the recording overlay: near-black
/// surfaces, hairline white strokes, continuous corners, and white at varying
/// opacity instead of accent colours. Settings windows force dark appearance
/// so this reads the same regardless of the system theme.
enum Theme {
    // Surfaces, darkest to lightest.
    static let sidebar = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let window = Color(red: 0.063, green: 0.063, blue: 0.074)
    static let raised = Color.white.opacity(0.04)
    static let raisedHover = Color.white.opacity(0.065)
    static let chip = Color.white.opacity(0.10)

    // Hairlines. `stroke` is the default edge, `strokeStrong` marks selection.
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.20)

    // Text ramp, matching the overlay's 0.85 / 0.7 pairing.
    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    /// Muted, low-saturation hues so each kind of model metadata reads as its
    /// own category on a near-black surface without turning the page into
    /// confetti. One hue per category, used nowhere else.
    enum Meta {
        /// How fast the model transcribes.
        static let speed = Color(red: 0.95, green: 0.76, blue: 0.38)
        /// Download size on disk.
        static let size = Color(red: 0.52, green: 0.72, blue: 0.97)
        /// Already downloaded.
        static let onDisk = Color(red: 0.44, green: 0.84, blue: 0.62)
        /// English-only family (Parakeet).
        static let english = Color(red: 0.40, green: 0.83, blue: 0.80)
        /// Multilingual family (Whisper).
        static let multilingual = Color(red: 0.68, green: 0.60, blue: 0.98)
    }

    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8

    /// Very slight vertical lift so large panes don't read as one flat slab.
    static var windowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.075, green: 0.075, blue: 0.086),
                Color(red: 0.055, green: 0.055, blue: 0.065),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Surfaces

extension View {
    /// Standard raised panel: soft white fill plus a hairline edge.
    func themeCard(
        radius: CGFloat = Theme.radius,
        fill: Color = Theme.raised,
        border: Color = Theme.stroke,
        borderWidth: CGFloat = 0.5
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(border, lineWidth: borderWidth)
        )
    }
}

extension View {
    /// Inset field surface, shared by the vocabulary and language inputs.
    func themeField(radius: CGFloat = Theme.radiusMedium) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Chips

/// Small pill for metadata, mirroring the overlay's KeyCap. Pass a `tint` to
/// mark which category the value belongs to; without one it stays neutral.
struct ThemeChip: View {
    var systemImage: String? = nil
    let text: String
    var tint: Color? = nil
    var emphasised: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall - 1, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall - 1, style: .continuous)
                .strokeBorder(tint?.opacity(0.22) ?? Color.clear, lineWidth: 0.5)
        )
    }

    private var foreground: Color {
        if let tint { return tint.opacity(0.95) }
        return emphasised ? Theme.text : Theme.textSecondary
    }

    private var fill: Color {
        if let tint { return tint.opacity(0.13) }
        return Color.white.opacity(emphasised ? 0.14 : 0.06)
    }
}

// MARK: - Buttons

/// Filled button for the primary action in a row. White on dark, no accent.
///
/// The hover state lives in a nested View rather than in the style itself.
/// ButtonStyle is not a View and is re-instantiated on every parent render, so
/// @State on the style is not a documented contract; only @Environment is.
struct ThemeButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ThemeButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct ThemeButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovered = false

        var body: some View {
            let base = prominent ? 0.90 : 0.08
            let lift = hovered ? (prominent ? 1.0 : 0.14) : base
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.black.opacity(0.88) : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? lift * 0.8 : lift))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                        .strokeBorder(prominent ? Color.clear : Theme.stroke, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// Icon-only button. Always carries a visible hover background so it doesn't
/// read as static decoration.
struct ThemeIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ThemeIconBody(configuration: configuration, size: size, destructive: destructive)
    }

    private struct ThemeIconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let destructive: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    hovered
                        ? (destructive ? Color.red.opacity(0.9) : Theme.text)
                        : Theme.textTertiary
                )
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .fill(Color.white.opacity(hovered ? (configuration.isPressed ? 0.16 : 0.10) : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

// MARK: - Waveform motif

/// Static version of the overlay's waveform, used to mark the model that is
/// actually loaded. Ties the two surfaces together without animating anything
/// in a settings window.
struct MiniWaveform: View {
    var barCount: Int = 9
    var height: CGFloat = 14
    var tint: Color = Theme.text

    private static let factors: [CGFloat] = [0.25, 0.5, 0.8, 1.0, 0.65, 1.0, 0.8, 0.5, 0.25]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let f = Self.factors[i % Self.factors.count]
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint.opacity(0.35 + 0.55 * Double(f)))
                    .frame(width: 2, height: max(2, height * f))
            }
        }
        .frame(height: height)
    }
}
