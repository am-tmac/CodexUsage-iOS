import XCTest
@testable import CodexUsageCore
final class UsageTests: XCTestCase {
    func testResetTimestampSameDayDifferentDayAndMissing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 18, minute: 30))!
        let week = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12, minute: 54))!
        let locale = Locale(identifier: "zh_CN")
        XCTAssertEqual(ResetTimestamp.text(nil, now: now, calendar: calendar, locale: locale), "重置时间未知")
        XCTAssertEqual(ResetTimestamp.text(today, now: now, calendar: calendar, locale: locale), "重置 18:30")
        let text = ResetTimestamp.text(week, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("9")); XCTAssertTrue(text.contains("18")); XCTAssertTrue(text.contains("12:54"))
        XCTAssertNotEqual(text, ResetTimestamp.text(today, now: now, calendar: calendar, locale: locale))
    }
    func testMissingWindowsStayUnknown() throws {
        for source in [#"{}"#, #"{"rate_limit":null}"#, #"{"rate_limit":{}}"#] {
            let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(source.utf8))
            XCTAssertNil(usage.rateLimit?.primaryWindow)
            XCTAssertNil(usage.rateLimit?.secondaryWindow)
        }
    }
    func testPercentClampsToValidRange() {
        XCTAssertEqual(UsageWindow(usedPercent: -20, resetAt: nil, limitWindowSeconds: nil).remaining, 100)
        XCTAssertEqual(UsageWindow(usedPercent: 150, resetAt: nil, limitWindowSeconds: nil).remaining, 0)
    }
    func testStaleAfterThirtyMinutesOrReset() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1900}}}"#.utf8))
        XCTAssertTrue(UsageSnapshot(usage: usage, updatedAt: now).isStale(at: now))
        let empty = try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8))
        XCTAssertFalse(UsageSnapshot(usage: empty, updatedAt: now).isStale(at: now))
        XCTAssertTrue(UsageSnapshot(usage: empty, updatedAt: now).isStale(at: now.addingTimeInterval(1801)))
    }
    func testUsedPercentBecomesRemaining() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":23,"reset_at":1800000000,"limit_window_seconds":18000}}}"#.utf8)
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        XCTAssertEqual(usage.rateLimit?.primaryWindow?.remaining, 77)
    }
    // MARK: - Account identity label (display only)
    func testAccountLabelFormatsIdentityAndPlanWithoutInventing() {
        XCTAssertEqual(AccountLabel.text(identity: "alex@example.com", plan: AccountLabel.plan("plus"), masked: false), "alex@example.com · Plus")
        // Missing/blank plan -> suffix omitted entirely; never guessed.
        XCTAssertEqual(AccountLabel.text(identity: "alex@example.com", plan: AccountLabel.plan("   "), masked: false), "alex@example.com")
        XCTAssertEqual(AccountLabel.text(identity: "alex@example.com", plan: AccountLabel.plan(nil), masked: false), "alex@example.com")
        // Missing/expired identity -> neutral placeholder, never empty or another account's name.
        XCTAssertEqual(AccountLabel.text(identity: nil, plan: nil, masked: false), AccountLabel.unknownIdentity)
        XCTAssertEqual(AccountLabel.text(identity: "   ", plan: AccountLabel.plan("pro"), masked: true), "未命名账号 · Pro")
    }
    func testAccountLabelMaskingNeverLeaksTheIdentity() {
        XCTAssertEqual(AccountLabel.mask("alex@example.com"), "ale***@example.com")
        XCTAssertEqual(AccountLabel.text(identity: "alex@example.com", plan: AccountLabel.plan("plus"), masked: true), "ale***@example.com · Plus")
        XCTAssertEqual(AccountLabel.mask("ab@example.com"), "a***@example.com")
        XCTAssertEqual(AccountLabel.mask("nonsense"), "non***")
        XCTAssertFalse(AccountLabel.text(identity: "alex@example.com", plan: nil, masked: true).contains("alex"))
        XCTAssertFalse(AccountLabel.text(identity: "a.b@c.d", plan: nil, masked: true).contains("a.b@c.d"))
    }
    func testCredentialsReadDisplayEmailFromIdTokenClaimsOnly() throws {
        func token(_ payload: [String: Any]) throws -> String {
            "header." + (try JSONSerialization.data(withJSONObject: payload)).base64EncodedString() + ".signature"
        }
        let direct = try Credentials(response: TokenResponse(accessToken: try token(["exp": 4_000_000_000]), refreshToken: "r", idToken: try token(["email": "alex@example.com"]), expiresIn: nil))
        XCTAssertEqual(direct.email, "alex@example.com")
        let nested = try Credentials(response: TokenResponse(accessToken: try token([:]), refreshToken: "r", idToken: try token(["https://api.openai.com/profile": ["email": "nested@example.com"]]), expiresIn: nil))
        XCTAssertEqual(nested.email, "nested@example.com")
        // No identity claim at all -> nil, so the label must fall back, not guess.
        let absent = try Credentials(response: TokenResponse(accessToken: try token([:]), refreshToken: "r", idToken: nil, expiresIn: 3600))
        XCTAssertNil(absent.email)
        // A rotation (or refresh grant) that omits the claim keeps the known display identity.
        let rotated = try Credentials(response: TokenResponse(accessToken: try token([:]), refreshToken: "r2", idToken: nil, expiresIn: 3600), previous: direct)
        XCTAssertEqual(rotated.email, "alex@example.com")
    }
    func testDisplayIdentityFallsBackToStoredAccessTokenClaimsWithoutTouchingAuth() throws {
        func token(_ payload: [String: Any]) throws -> String {
            "header." + (try JSONSerialization.data(withJSONObject: payload)).base64EncodedString() + ".signature"
        }
        let access = try token(["sub": "unit-subject", "https://api.openai.com/profile": ["email": "alex@example.com"]])
        // Exactly a build-5 stored record: no `email` key at all.
        let raw = try JSONSerialization.data(withJSONObject: ["accessToken": access, "refreshToken": "unit-r", "accountID": "unit-account", "expiresAt": 0])
        let legacy = try JSONDecoder().decode(Credentials.self, from: raw)
        XCTAssertNil(legacy.email)
        XCTAssertEqual(legacy.displayIdentity, "alex@example.com")
        // The recovered value is a copy: tokens/expiry are carried verbatim and the routing
        // identity (sub + account) is unchanged, so nothing about auth can move.
        let rebuilt = Credentials(accessToken: legacy.accessToken, refreshToken: legacy.refreshToken, accountID: legacy.accountID,
                                  email: try XCTUnwrap(legacy.recoveredDisplayIdentity()), expiresAt: legacy.expiresAt)
        XCTAssertEqual(rebuilt.accessToken, legacy.accessToken)
        XCTAssertEqual(rebuilt.refreshToken, "unit-r")
        XCTAssertEqual(rebuilt.expiresAt, legacy.expiresAt)
        XCTAssertEqual(SharedStorage.identity(rebuilt), SharedStorage.identity(legacy))
        // No usable claim: a malformed token or a JWT without identity stays nil -> placeholder.
        XCTAssertNil(try Credentials(response: TokenResponse(accessToken: "unit-not-a-jwt", refreshToken: "r", idToken: nil, expiresIn: 3600)).displayIdentity)
        XCTAssertNil(try Credentials(response: TokenResponse(accessToken: try token(["exp": 1]), refreshToken: "r", idToken: nil, expiresIn: 3600)).recoveredDisplayIdentity())
        // A stored (or already-known) identity is never replaced by a token claim.
        let stored = try Credentials(response: TokenResponse(accessToken: access, refreshToken: "r", idToken: nil, expiresIn: nil))
        XCTAssertEqual(stored.displayIdentity, "alex@example.com")
        XCTAssertNil(stored.recoveredDisplayIdentity())
    }

    func testCardOrderMoveMatchesListOnMoveOffsets() {
        let keys = ["a", "b", "c", "d"]
        // dragging "a" below "c": onMove reports source 0 -> destination 3
        XCTAssertEqual(CardOrder.move(0, to: 3, in: keys), ["b", "c", "a", "d"])
        // dragging "d" above "b": source 3 -> destination 1
        XCTAssertEqual(CardOrder.move(3, to: 1, in: keys), ["a", "d", "b", "c"])
        // dragging to the very end: source 1 -> destination 4
        XCTAssertEqual(CardOrder.move(1, to: 4, in: keys), ["a", "c", "d", "b"])
        XCTAssertEqual(CardOrder.move(0, to: 0, in: keys), keys)
        XCTAssertEqual(CardOrder.move(9, to: 1, in: keys), keys)
    }
}
