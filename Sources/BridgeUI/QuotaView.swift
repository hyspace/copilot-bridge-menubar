import SwiftUI
import BridgeCore

/// Keep account-reported amounts independent of the provider's rounded percentage.
struct QuotaPresentation {
    let snapshot: QuotaSnapshot
    var used: Double? {
        if snapshot.kind == .credits, let reported = valid(snapshot.creditsUsed) { return reported }
        guard !snapshot.unlimited, let limit = valid(snapshot.entitlement),
              let remaining = valid(snapshot.remaining), remaining <= limit else { return nil }
        return limit - remaining
    }
    var usedIsDerived: Bool {
        used != nil && !(snapshot.kind == .credits && valid(snapshot.creditsUsed) != nil)
    }
    var remaining: Double? { valid(snapshot.remaining) }
    var remainingFraction: Double? {
        guard !snapshot.unlimited else { return nil }
        if let percent = valid(snapshot.percentRemaining), percent <= 100 { return percent / 100 }
        guard let limit = valid(snapshot.entitlement), limit > 0,
              let remaining, remaining <= limit else { return nil }
        return remaining / limit
    }
    var usedTitle: String {
        let unit = snapshot.kind == .credits ? "Credits used" : "Used"
        return unit + (usedIsDerived ? " (derived)" : "")
    }
    var remainingTitle: String { snapshot.kind == .credits ? "Credits remaining" : "Remaining" }
    var remainingText: String {
        if snapshot.unlimited { return "Unlimited" }
        guard let fraction = remainingFraction else { return "—" }
        return (fraction * 100).formatted(.number.locale(ActivityText.locale).precision(.fractionLength(0...1))) + "%"
    }
    var remainingHelp: String {
        if snapshot.unlimited { return "GitHub reports an unlimited quota; no remaining percentage applies." }
        let unit = snapshot.kind == .credits ? "credits" : "quota units"
        return remaining.map { ActivityText.number($0) + " \(unit) remaining." }
            ?? "The remaining amount was not reported by GitHub."
    }
    var usedHelp: String {
        usedIsDerived
            ? "Derived from the account limit minus remaining quota, not from token counts."
            : "Account-wide usage reported by GitHub, including other clients. Missing usage is unknown, not zero."
    }
    private func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// The consumed portion always starts on the left; unspent quota stays green on the right.
struct QuotaBar: View {
    let remainingFraction: Double
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Color.secondary.opacity(0.25).frame(width: geometry.size.width * (1 - remainingFraction))
                Color.green.frame(width: geometry.size.width * remainingFraction)
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Account quota")
        .accessibilityValue("\(ActivityText.number((1 - remainingFraction) * 100))% used, \(ActivityText.number(remainingFraction * 100))% remaining")
    }
}

struct QuotaAmounts: View {
    let snapshot: QuotaSnapshot
    var observedAt: Date? = nil
    var body: some View {
        let presentation = QuotaPresentation(snapshot: snapshot)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.used.map(ActivityText.number) ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Label(presentation.usedTitle, systemImage: "circle.fill")
                        .labelStyle(QuotaLegendStyle(color: .secondary))
                        .help(presentation.usedHelp)
                }.help(presentation.usedHelp)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(presentation.remainingText)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                    Label(presentation.remainingTitle, systemImage: "circle.fill")
                        .labelStyle(QuotaLegendStyle(color: .green))
                }.help(presentation.remainingHelp)
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            if let fraction = presentation.remainingFraction {
                QuotaBar(remainingFraction: fraction)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let progress = QuotaMonthProgress(now: context.date, observedAt: observedAt, reset: snapshot.reset)
                    VStack(alignment: .leading, spacing: 5) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.accentColor.opacity(0.12))
                                Capsule().fill(Color.accentColor)
                                    .frame(width: geometry.size.width * progress.fraction)
                            }
                        }.frame(height: 3)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityHidden(true)
                        HStack(spacing: 4) {
                            Text("Month elapsed (UTC)")
                            Spacer(minLength: 0)
                            Text((progress.fraction * 100).formatted(.number.locale(ActivityText.locale)
                                .precision(.fractionLength(0...1))) + "%")
                        }
                        if progress.canCompareBalance {
                            let difference = (1 - fraction - progress.fraction) * 100
                            Text(abs(difference) < 0.5 ? "Usage is in line with month progress"
                                 : "Usage \(abs(difference).formatted(.number.locale(ActivityText.locale).precision(.fractionLength(0...1)))) pp \(difference > 0 ? "ahead of" : "behind") month progress")
                        } else {
                            Text("Refresh balance to compare usage pace")
                        }
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Calendar-month progress in UTC, measured left to right like used quota. This is a linear reference, not a billing-period claim or spending forecast. pp means percentage points. A balance older than 15 minutes or past its reset is not compared.")
                }
            }
        }
    }
}

private struct QuotaLegendStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(color)
            configuration.title.font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
