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
