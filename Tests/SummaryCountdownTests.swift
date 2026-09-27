import XCTest
@testable import CodexUsageCore

/// build 27: collapsed-card summary + reset countdowns. Everything is derived from the reset time
/// and remaining share the service reported; nothing is estimated.
final class SummaryCountdownTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testCountdownUnits() {
        let now = date("2026-09-27 13:48")
        XCTAssertEqual(Countdown.text(to: date("2026-10-03 09:12"), now: now), "5天19时")
        XCTAssertEqual(Countdown.text(to: date("2026-09-27 16:02"), now: now), "2时14分")
        XCTAssertEqual(Countdown.text(to: date("2026-09-27 14:02"), now: now), "14分")
        XCTAssertEqual(Countdown.text(to: date("2026-09-28 14:48"), now: now), "1天01时")
        // Under a minute still says 1分, never 0分.
        XCTAssertEqual(Countdown.text(to: now.addingTimeInterval(20), now: now), "1分")
    }

    func testCountdownNeverInventsAValue() {
        let now = date("2026-09-27 13:48")
        XCTAssertNil(Countdown.text(to: nil, now: now))
        XCTAssertNil(Countdown.text(to: now, now: now))
        XCTAssertNil(Countdown.text(to: date("2026-09-27 13:00"), now: now))
        XCTAssertEqual(Countdown.short(nil, now: now), "重置时间未知")
        XCTAssertEqual(Countdown.short(date("2026-09-27 13:00"), now: now), "已到重置时间")
        XCTAssertEqual(Countdown.resetLine(nil, now: now), "重置时间未知")
    }

    func testResetLineKeepsTheAbsoluteMoment() {
        let now = date("2026-09-27 13:48")
        XCTAssertEqual(Countdown.resetLine(date("2026-09-27 16:02"), now: now, calendar: calendar), "2时14分后重置 · 今天 16:02")
        XCTAssertEqual(Countdown.resetLine(date("2026-10-03 09:12"), now: now, calendar: calendar), "5天19时后重置 · 10月3日 09:12")
        XCTAssertEqual(Countdown.resetLine(date("2026-09-27 13:00"), now: now, calendar: calendar), "已到重置时间 · 今天 13:00")
    }

    func testSummaryPicksTheTightestReportedWindow() {
        let reset = date("2026-10-03 09:12")
        let pick = QuotaSummary.tightest([
            .init(label: "5 小时", remaining: 81, reset: nil),
            .init(label: "每周", remaining: 43, reset: reset),
        ])
        XCTAssertEqual(pick?.label, "每周")
        XCTAssertEqual(pick?.remaining, 43)
        XCTAssertEqual(pick?.reset, reset)
    }

    func testSummarySkipsMissingWindowsAndReturnsNilWhenNothingWasReported() {
        let pick = QuotaSummary.tightest([
            .init(label: "5 小时", remaining: nil, reset: nil),
            .init(label: "7 天", remaining: 38, reset: nil),
        ])
        XCTAssertEqual(pick?.label, "7 天")
        XCTAssertNil(QuotaSummary.tightest([.init(label: "5 小时", remaining: nil, reset: nil)]))
        XCTAssertNil(QuotaSummary.tightest([]))
    }

    func testSummaryTieKeepsTheFirstWindow() {
        let pick = QuotaSummary.tightest([
            .init(label: "5 小时", remaining: 50, reset: nil),
            .init(label: "每周", remaining: 50, reset: nil),
        ])
        XCTAssertEqual(pick?.label, "5 小时")
    }

    func testLowThresholdIsTwentyPercentInclusive() {
        XCTAssertTrue(QuotaSummary.isLow(20))
        XCTAssertTrue(QuotaSummary.isLow(0))
        XCTAssertFalse(QuotaSummary.isLow(20.5))
        XCTAssertFalse(QuotaSummary.isLow(nil))
    }
}
