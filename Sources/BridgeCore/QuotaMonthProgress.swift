import Foundation

/// A calendar-month reference, not an inferred billing period or a cost forecast.
/// UTC avoids changing the reference when the system timezone or DST changes.
public struct QuotaMonthProgress {
    public let fraction: Double
    public let canCompareBalance: Bool

    public init(now: Date, observedAt: Date?, reset: String?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = calendar.dateInterval(of: .month, for: now)!
        fraction = min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
        let resetDate = reset.flatMap(Self.parseReset)
        // Never compare last month's cached balance against this month's clock,
        // or continue comparing past a provider-reported reset.
        canCompareBalance = observedAt.map {
            $0 >= interval.start && $0 <= now && now.timeIntervalSince($0) <= 900
        } == true && (reset == nil || resetDate.map { $0 > now } == true)
    }
    private static func parseReset(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.isLenient = false
        guard value.count == 10 else { return nil }
        return dateOnly.date(from: value)
    }
}
