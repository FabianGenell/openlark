import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 0) {
            WaveformBars(levels: model.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Text(model.isProcessing ? "Transcribing…" : "Voice")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Text(model.isProcessing ? "" : "Stop")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))

                KeyCap(symbol: "command")
                KeyCap(symbol: "arrow.up")

                Text(model.isProcessing ? "" : "Cancel")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.leading, 6)

                KeyCap(text: "esc")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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

struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    let h = max(2, CGFloat(level) * geo.size.height)
                    let opacity = 0.35 + 0.65 * Double(level)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(opacity))
                        .frame(width: 3, height: h)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
