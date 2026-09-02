import SwiftUI

/// Horizontal card showing four usage metrics. Matches the layout shown in the
/// project screenshot: 4 columns, big number on top, soft label below.
struct StatsCard: View {
    let stats: UsageStats

    var body: some View {
        HStack(spacing: 0) {
            stat(value: "\(Int(stats.averageWPM.rounded()))", unit: "WPM", label: "Average speed")
            divider
            stat(value: formattedWords, unit: nil, label: "Words this week")
            divider
            stat(value: "\(stats.appsUsedThisWeek)", unit: nil, label: "Apps used")
            divider
            stat(value: formattedTimeSaved, unit: nil, label: "Saved this week")
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .themeCard(radius: Theme.radiusLarge)
    }

    /// Height is pinned deliberately. A Rectangle with only a width set is
    /// vertically greedy, so in a container that offers more height than the
    /// card needs (the History window's VStack, as opposed to the scroll view
    /// in Settings) it stretched the whole card to fill the space.
    ///
    /// The horizontal padding is what puts it in the middle. The columns sit
    /// flush against each other, so without a gutter the rule lands hard up
    /// against the next column's number instead of between the two.
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 32)
            .padding(.horizontal, 8)
    }

    private func stat(value: String, unit: String?, label: String) -> some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        // Centred, not leading. Left-aligning inside equal-width columns left
        // dead space to the right of every label, so each rule read as though
        // it belonged to the column on its right rather than sitting between
        // the two.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var formattedWords: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: stats.wordsThisWeek)) ?? "0"
    }

    private var formattedTimeSaved: String {
        let total = stats.timeSavedThisWeek
        if total < 60 {
            return "\(Int(total))s"
        }
        if total < 60 * 60 {
            return "\(Int(total / 60))m"
        }
        let hours = total / 3600
        if hours < 10 {
            return String(format: "%.1f hrs", hours)
        }
        return "\(Int(hours)) hrs"
    }
}
