import SwiftUI
import BridgeCore

enum ActivityText {
    static let locale = Locale(identifier: "en_US")
    static func number(_ value: Double) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...4)))
    }
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).month(.abbreviated).day().year())
    }
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).hour().minute())
    }
    static func tokens(_ day: ActivityDay) -> String {
        if day.tokens == 0 && day.hasUnknownUsage { return "Tokens unreported" }
        let count = day.tokens.formatted(.number.locale(locale).notation(.compactName))
        return "\(count) recorded tokens"
    }
    static func balance(_ day: ActivityDay) -> String {
        guard let observation = day.quota else { return "Credits: not recorded" }
        let value = observation.snapshot
        let unit = value.kind == .credits ? "credits" : value.kind == .premiumInteractions ? "premium interactions" : "chat requests"
        if value.unlimited { return "Unlimited \(unit)" }
        guard let remaining = value.remaining else { return "\(value.title): unknown" }
        return "\(number(remaining)) \(unit) remaining"
    }
    static func tooltip(_ day: ActivityDay) -> String {
        var lines = [
            date(day.date),
            day.tokens == 0 && day.hasUnknownUsage ? "Token usage was not reported"
                : "\(day.tokens.formatted(.number.locale(locale))) recorded tokens",
            "Reported input: \(day.usage.input) · Output: \(day.usage.output) · Cached: \(day.usage.cached)",
            "\(day.usage.requests) requests · \(day.usage.errors) errors",
            balance(day)
        ]
        if day.hasUnknownUsage { lines += ["\(day.usage.unknown) requests have missing token usage."] }
        if let observation = day.quota {
            lines += ["Account-wide balance observed \(date(observation.observedAt)) at \(time(observation.observedAt))."]
            if let used = observation.snapshot.creditsUsed {
                lines += ["Credits used this billing cycle: \(number(used))"]
            }
            if observation.snapshot.kind != .credits { lines += ["This quota is not measured in credits."] }
        } else {
            lines += ["Historical credits cannot be reconstructed from token counts."]
        }
        return lines.joined(separator: "\n")
    }
}

/// A bounded, native calendar grid with token intensity and real quota snapshots.
/// The detail panel responds to hover, click and keyboard focus without opening another window.
struct ActivityHeatmap: View {
    let days: [ActivityDay]
    @State private var hovered: String?
    @State private var selected: String?
    @FocusState private var focused: String?
    @Environment(\.colorScheme) private var scheme

    init(days: [ActivityDay], initialSelection: String? = nil) {
        self.days = days
        _selected = State(initialValue: initialSelection)
    }
    private let side: CGFloat = 10
    private let gap: CGFloat = 2.5
    private var maximum: Int64 { days.map(\.tokens).max() ?? 0 }
    private var highlighted: ActivityDay? {
        let key = hovered ?? focused ?? selected
        return days.first { $0.id == key && !$0.isFuture } ?? days.last { !$0.isFuture }
    }
    private func color(_ level: Int) -> Color {
        let palette: [UInt32] = scheme == .dark
            ? [0x252C35, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
            : [0xEFF2F5, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let hex = palette[min(4, max(0, level))]
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private var months: [Int: String] {
        let calendar = ActivityCalendar.local
        var result: [Int: String] = [:]
        for (index, day) in days.enumerated() where !day.isFuture {
            if calendar.component(.day, from: day.date) == 1 {
                result[index / 7] = day.date.formatted(.dateTime.locale(ActivityText.locale).month(.abbreviated))
            }
        }
        return result
    }

    var body: some View {
        let monthLabels = months
        let peak = maximum
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Activity") {
                Text("26 weeks").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: gap) {
                    Color.clear.frame(height: 12)
                    ForEach(0..<7) { row in
                        Text(["", "Mon", "", "Wed", "", "Fri", ""][row])
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                            .frame(width: 24, height: side, alignment: .leading)
                    }
                }.accessibilityHidden(true)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<(days.count / 7), id: \.self) { week in
                        VStack(spacing: gap) {
                            Color.clear.frame(width: side, height: 12)
                                .overlay(alignment: .leading) {
                                    if let month = monthLabels[week] {
                                        Text(month).font(.system(size: 8)).foregroundStyle(.secondary).fixedSize()
                                    }
                                }.accessibilityHidden(true)
                            ForEach(0..<7, id: \.self) { weekday in
                                tile(days[week * 7 + weekday], peak: peak)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Text("Input + output tokens").font(.system(size: 8))
                Spacer(minLength: 3)
                Text("Less").padding(.trailing, 2)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 9, height: 9)
                }
                Text("More").padding(.leading, 2)
            }.font(.system(size: 8)).foregroundStyle(.secondary).accessibilityHidden(true)
            if let day = highlighted {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ActivityText.date(day.date)).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text(ActivityText.tokens(day)).monospacedDigit()
                    }.font(.system(size: 10))
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard").font(.system(size: 9))
                        Text(ActivityText.balance(day)).monospacedDigit()
                        Spacer(minLength: 0)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(day.quota.map { "Account snapshot at \(ActivityText.time($0.observedAt))" }
                         ?? "Hover a day for tokens and its recorded credit balance.")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ActivityText.tooltip(day))
                .accessibilityIdentifier("activity-details")
            }
        }
    }
    @ViewBuilder private func tile(_ day: ActivityDay, peak: Int64) -> some View {
        if day.isFuture {
            Color.clear.frame(width: side, height: side).accessibilityHidden(true)
        } else {
            Button { selected = day.id } label: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(day.intensity(maximum: peak)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(highlighted?.id == day.id ? Color.primary.opacity(0.6)
                                          : day.hasUnknownUsage ? Color.secondary.opacity(0.6) : .clear,
                                          style: StrokeStyle(lineWidth: 1, dash: day.hasUnknownUsage ? [2, 1] : []))
                    }
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused, equals: day.id)
            .onHover { inside in
                if inside { hovered = day.id }
                else if hovered == day.id { hovered = nil }
            }
            .help(ActivityText.tooltip(day))
            .accessibilityLabel(ActivityText.tooltip(day))
            .accessibilityIdentifier("activity-day-\(day.id)")
        }
    }
}
