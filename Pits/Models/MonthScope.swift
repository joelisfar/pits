import Foundation

/// Calendar-month scope used for the conversation list filter.
struct MonthScope: Equatable, Hashable, Codable, Comparable {
    let year: Int
    let month: Int

    static func current(in cal: Calendar = Calendar.current) -> MonthScope {
        from(date: Date(), in: cal)
    }

    static func from(date: Date, in cal: Calendar = Calendar.current) -> MonthScope {
        let comps = cal.dateComponents([.year, .month], from: date)
        return MonthScope(year: comps.year ?? 1970, month: comps.month ?? 1)
    }

    /// Half-open `[startOfMonth, startOfNextMonth)` range.
    func dateRange(in cal: Calendar = Calendar.current) -> Range<Date> {
        let start = cal.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        return start..<end
    }

    func displayName(locale: Locale = Locale.current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "LLLL yyyy"
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let date = cal.date(from: DateComponents(year: year, month: month, day: 1))!
        return f.string(from: date)
    }

    static func < (lhs: MonthScope, rhs: MonthScope) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.month < rhs.month
    }

    /// Contiguous descending list of months from `latest` down to `earliest`.
    static func range(from earliest: MonthScope, through latest: MonthScope) -> [MonthScope] {
        guard earliest <= latest else { return [] }
        var result: [MonthScope] = []
        var cur = latest
        while cur >= earliest {
            result.append(cur)
            if cur.month == 1 {
                cur = MonthScope(year: cur.year - 1, month: 12)
            } else {
                cur = MonthScope(year: cur.year, month: cur.month - 1)
            }
        }
        return result
    }
}
