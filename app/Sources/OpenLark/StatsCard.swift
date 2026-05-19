import SwiftUI

/// Horizontal card showing four usage metrics. Matches the layout shown in the
/// project screenshot — 4 columns, big number on top, soft label below.
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
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private func stat(value: String, unit: String?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                if let unit {
                    Text(unit)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
