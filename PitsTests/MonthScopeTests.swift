import XCTest
@testable import Pits

final class MonthScopeTests: XCTestCase {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func test_dateRange_isStartOfMonthInclusiveToStartOfNextMonthExclusive() {
        let m = MonthScope(year: 2026, month: 4)
        let r = m.dateRange(in: cal())
        let comps = cal().dateComponents([.year, .month, .day, .hour], from: r.lowerBound)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 0)
        let upper = cal().dateComponents([.year, .month, .day], from: r.upperBound)
        XCTAssertEqual(upper.year, 2026)
        XCTAssertEqual(upper.month, 5)
        XCTAssertEqual(upper.day, 1)
    }

    func test_contains_includesLowerBound_excludesUpperBound() {
        let m = MonthScope(year: 2026, month: 4)
        let r = m.dateRange(in: cal())
        XCTAssertTrue(r.contains(r.lowerBound))
        XCTAssertFalse(r.contains(r.upperBound))
    }

    func test_from_date_extractsYearAndMonth() {
        let date = cal().date(from: DateComponents(year: 2026, month: 4, day: 21, hour: 14))!
        let m = MonthScope.from(date: date, in: cal())
        XCTAssertEqual(m.year, 2026)
        XCTAssertEqual(m.month, 4)
    }

    func test_displayName_isMonthAndYear() {
        let m = MonthScope(year: 2026, month: 4)
        XCTAssertEqual(m.displayName(locale: Locale(identifier: "en_US_POSIX")), "April 2026")
    }

    func test_comparable_chronological() {
        XCTAssertLessThan(MonthScope(year: 2025, month: 12), MonthScope(year: 2026, month: 1))
        XCTAssertLessThan(MonthScope(year: 2026, month: 1), MonthScope(year: 2026, month: 4))
    }

    func test_monthsRange_inclusiveContiguous_descending() {
        let earliest = MonthScope(year: 2025, month: 11)
        let latest   = MonthScope(year: 2026, month: 2)
        let months = MonthScope.range(from: earliest, through: latest)
        XCTAssertEqual(months, [
            MonthScope(year: 2026, month: 2),
            MonthScope(year: 2026, month: 1),
            MonthScope(year: 2025, month: 12),
            MonthScope(year: 2025, month: 11),
        ])
    }
}
