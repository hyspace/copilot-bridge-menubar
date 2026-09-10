import Foundation

public struct QuotaObservation: Codable, Equatable {
    public var snapshot: QuotaSnapshot
    public var observedAt: Date
    public init(snapshot: QuotaSnapshot, observedAt: Date) {
        self.snapshot = snapshot; self.observedAt = observedAt
    }
}

public struct ActivityDay: Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var usage: UsageTotals
    public var providers: [UsageProvider: UsageTotals] = [:]
    public var quota: QuotaObservation?
    public var isFuture: Bool
    public init(date: Date, usage: UsageTotals = UsageTotals(), quota: QuotaObservation? = nil,
                isFuture: Bool = false, calendar: Calendar = ActivityCalendar.local) {
        self.id = ActivityCalendar.key(date, calendar: calendar)
        self.date = date; self.usage = usage; self.quota = quota; self.isFuture = isFuture
    }
    public var tokens: Int64 { usage.input + usage.output } // Cached tokens are already in input.
    public var hasUnknownUsage: Bool { usage.unknown > 0 }
    public var hasUnknownCredits: Bool { usage.unknownCredits > 0 }
    public var hasIncompleteUsage: Bool { hasUnknownUsage }
    public func intensity(maximum: Int64) -> Int {
        guard tokens > 0, maximum > 0 else { return 0 }
        return min(4, max(1, Int(ceil(Double(tokens) / Double(maximum) * 4))))
    }
}

public enum ActivityCalendar {
    public static var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }
    public static func key(_ date: Date, calendar: Calendar = local) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public static func grid(ending: Date = Date(), weeks: Int = 26,
                            calendar: Calendar = local) -> [ActivityDay] {
        let today = calendar.startOfDay(for: ending)
        let weekdayOffset = calendar.component(.weekday, from: today) - 1
        let count = min(53, max(1, weeks))
        guard let first = calendar.date(byAdding: .day,
            value: -(count - 1) * 7 - weekdayOffset, to: today) else { return [] }
        return (0..<(count * 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            return ActivityDay(date: date, isFuture: date > today, calendar: calendar)
        }
    }
}
