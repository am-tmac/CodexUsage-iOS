import XCTest
@testable import CodexUsageCore

/// Failure modes found in the 2026-09 code review. Each test pins one way the App could lose a
/// credential, show a guessed number, or accept a login it should reject.
final class ReviewFixTests: XCTestCase {
    override class func setUp() { super.setUp(); TestContainer.install() }

    // MARK: - Rotated refresh tokens must never be silently dropped

    func testRotationPersistenceRetriesOnceThenSucceeds() throws {
        var calls = 0
        try RotationPersistence.save { calls += 1; if calls == 1 { throw ServiceError.storage("locked") } }
        XCTAssertEqual(calls, 2)
    }

    func testRotationPersistenceFailsLoudlyAfterRetry() {
        var calls = 0
        XCTAssertThrowsError(try RotationPersistence.save { calls += 1; throw ServiceError.storage("locked") })
        XCTAssertEqual(calls, 2)
    }

    func testClaudeRotationThatCannotBeSavedAbortsBeforeUsingTheNewToken() async throws {
        let transport = ScriptedTransport([(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh"}"#, 200),
                                           (#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#, 200)])
        var saved: [String] = []
        let store = ClaudeCredentialStore(
            load: { _ in ClaudeCredential(refreshToken: "old-refresh", obtainedAt: Date()) },
            save: { value, _ in saved.append(value.refreshToken); throw ClaudeFailure.storage })
        try? FileManager.default.removeItem(at: ClaudeStore.snapshotURL())
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(ClaudeStore.id))
        let service = ClaudeService(api: ClaudeAPI(transport: transport), store: store)
        do { _ = try await service.refresh(widget: false, permission: { true }); XCTFail("must fail") }
        catch let error as ClaudeFailure { XCTAssertEqual(error, .storage) }
        XCTAssertEqual(saved, ["rotated-refresh", "rotated-refresh"], "one retry, never the old value")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "usage must not be fetched with an unsaved rotation")
        XCTAssertNil(ClaudeStore.snapshot())
    }

    func testClaudeRotationIsSavedBeforeUsageIsFetched() async throws {
        let transport = ScriptedTransport([(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh"}"#, 200),
                                           (#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#, 200)])
        var saved: [String] = []
        let store = ClaudeCredentialStore(
            load: { _ in ClaudeCredential(refreshToken: "old-refresh", obtainedAt: Date()) },
            save: { value, _ in saved.append(value.refreshToken) })
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(ClaudeStore.id))
        let snapshot = try await ClaudeService(api: ClaudeAPI(transport: transport), store: store)
            .refresh(widget: false, permission: { true })
        XCTAssertEqual(saved, ["rotated-refresh"])
        XCTAssertEqual(snapshot.fiveHour?.remaining, 90)
    }

    // MARK: - build 28: Claude keeps its access token like CLIProxyAPI (rotate a few times a day)

    private func claudeService(_ transport: ScriptedTransport, credential: ClaudeCredential,
                               saved: @escaping (ClaudeCredential) -> Void = { _ in }) -> ClaudeService {
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(ClaudeStore.id))
        return ClaudeService(api: ClaudeAPI(transport: transport),
                             store: ClaudeCredentialStore(load: { _ in credential }, save: { value, _ in saved(value) }))
    }
    private let usageReply = (#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#, 200)

    func testValidAccessTokenIsReusedWithoutRotating() async throws {
        let transport = ScriptedTransport([usageReply])
        var saves = 0
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        let snapshot = try await claudeService(transport, credential: credential, saved: { _ in saves += 1 })
            .refresh(widget: false, permission: { true })
        XCTAssertEqual(snapshot.fiveHour?.remaining, 90)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "usage only — no token exchange")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        XCTAssertEqual(saves, 0, "the refresh token is untouched")
    }

    func testAccessTokenInsideTheFiveMinuteMarginIsRotatedAndSavedWithItsExpiry() async throws {
        let transport = ScriptedTransport([(#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#, 200), usageReply])
        var saved: [ClaudeCredential] = []
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(120))
        _ = try await claudeService(transport, credential: credential, saved: { saved.append($0) })
            .refresh(widget: false, permission: { true })
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].refreshToken, "r2")
        XCTAssertEqual(saved[0].accessToken, "a2")
        let left = try XCTUnwrap(saved[0].accessExpiresAt).timeIntervalSinceNow
        XCTAssertEqual(left, 28800, accuracy: 60)
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer a2")
    }

    func testLegacyRefreshOnlyRecordDecodesAndRotatesOnce() async throws {
        let legacy = try JSONDecoder().decode(ClaudeCredential.self,
                                              from: Data(#"{"refreshToken":"r1","obtainedAt":0}"#.utf8))
        XCTAssertNil(legacy.usableAccessToken())
        let transport = ScriptedTransport([(#"{"access_token":"a2","expires_in":28800}"#, 200), usageReply])
        var saved: [ClaudeCredential] = []
        _ = try await claudeService(transport, credential: legacy, saved: { saved.append($0) })
            .refresh(widget: false, permission: { true })
        XCTAssertEqual(saved.first?.refreshToken, "r1", "no rotated token in the reply keeps the old one")
        XCTAssertEqual(saved.first?.accessToken, "a2")
    }

    func testWidgetNeverRotatesAndServesTheCacheWhenTheAccessTokenIsSpent() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 50, reset: nil), sevenDay: nil, updatedAt: Date(timeIntervalSince1970: 1))
        try ClaudeStore.save(good)
        let transport = ScriptedTransport([])
        var saves = 0
        let expired = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                       accessExpiresAt: Date().addingTimeInterval(-10))
        let value = try await claudeService(transport, credential: expired, saved: { _ in saves += 1 })
            .refresh(widget: true, permission: { true })
        XCTAssertEqual(value, good)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(saves, 0)
    }

    func testWidgetUsesAValidAccessToken() async throws {
        let transport = ScriptedTransport([usageReply])
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        let value = try await claudeService(transport, credential: credential).refresh(widget: true, permission: { true })
        XCTAssertEqual(value.sevenDay?.remaining, 80)
    }

    func testRevokedAccessTokenRotatesOnceInTheApp() async throws {
        let transport = ScriptedTransport([("{}", 401), (#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#, 200), usageReply])
        var saved: [ClaudeCredential] = []
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        _ = try await claudeService(transport, credential: credential, saved: { saved.append($0) })
            .refresh(widget: false, permission: { true })
        XCTAssertEqual(saved.map(\.refreshToken), ["r2"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    // MARK: - Antigravity must not overwrite a good cache with an error

    private func assist() -> Data { Data(#"{"planInfo":{"planType":"g1-pro-tier","monthlyPromptCredits":1000},"availablePromptCredits":320,"cloudaicompanionProject":"p1"}"#.utf8) }

    func testAntigravityModelErrorsOtherThan403AreNotTreatedAsNoQuota() async {
        for status in [401, 429, 500] {
            let api = AntigravityAPI(transport: RoutedTransport(models: (Data(), status), assist: assist()))
            do { _ = try await api.usage(refreshToken: "1//refresh"); XCTFail("HTTP \(status) must throw") } catch {}
        }
        let network = AntigravityAPI(transport: RoutedTransport(models: nil, assist: assist()))
        do { _ = try await network.usage(refreshToken: "1//refresh"); XCTFail("network failure must throw") } catch {}
    }

    func testAntigravity403OnModelsKeepsTheCredits() async throws {
        let api = AntigravityAPI(transport: RoutedTransport(models: (Data(), 403), assist: assist()))
        let usage = try await api.usage(refreshToken: "1//refresh")
        XCTAssertEqual(usage.availableCredits, 320)
        XCTAssertTrue(usage.quotas.isEmpty)
    }

    func testAntigravityEmptyAssistWithNoModelsIsMalformedNotZero() async {
        let api = AntigravityAPI(transport: RoutedTransport(models: (Data(), 403), assist: Data("{}".utf8)))
        do { _ = try await api.usage(refreshToken: "1//refresh"); XCTFail("must throw") }
        catch let error as AntigravityError { XCTAssertEqual(error, .malformed) } catch { XCTFail("\(error)") }
    }

    func testAntigravityFailedRefreshKeepsTheLastGoodSnapshot() async throws {
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(AntigravityStore.account))
        let models = Data(#"{"models":{"gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.4}}}}"#.utf8)
        let good = try await AntigravityService(api: AntigravityAPI(transport: RoutedTransport(models: (models, 200), assist: assist())))
            .refresh(token: "1//refresh", widget: false)
        let failing = AntigravityService(api: AntigravityAPI(transport: RoutedTransport(models: (Data(), 429), assist: assist())))
        do { _ = try await failing.refresh(token: "1//refresh", widget: false); XCTFail("must fail") } catch {}
        XCTAssertEqual(AntigravityStore.snapshot(), good)
    }

    func testAntigravityWidgetRefreshNeedsPermissionAndSendsNothingWithoutIt() async {
        let transport = CountingTransport()
        do { _ = try await AntigravityService(api: AntigravityAPI(transport: transport)).refresh(token: "1//refresh", widget: true, permission: { false }); XCTFail("must fail") }
        catch let error as AntigravityError { XCTAssertEqual(error, .storage) } catch { XCTFail("\(error)") }
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testAntigravityWidgetRefreshHonoursBackoff() async throws {
        let id = AntigravityStore.account
        var attempt = WidgetRefreshAttempt()
        attempt.fail(Date())
        try attempt.save(id)
        let transport = CountingTransport()
        do { _ = try await AntigravityService(api: AntigravityAPI(transport: transport)).refresh(token: "1//refresh", widget: true, permission: { true }) }
        catch {}
        let count = await transport.count
        XCTAssertEqual(count, 0, "a backed-off widget refresh must not call Google")
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(id))
    }

    // MARK: - Pasted Claude codes must belong to this login

    func testPastedCodeWithAForeignStateIsRejected() {
        XCTAssertNil(ClaudeOAuth.parsePastedCode("abc#someone-else", expectedState: "mine"))
        XCTAssertEqual(ClaudeOAuth.parsePastedCode("abc#mine", expectedState: "mine"), .code("abc", "mine"))
        XCTAssertEqual(ClaudeOAuth.parsePastedCode("abc", expectedState: "mine"), .code("abc", "mine"))
        XCTAssertNil(ClaudeOAuth.parsePastedCode("abc#mine", expectedState: ""), "no login in progress")
    }

    // MARK: - Corrupt saved card order must not crash launch

    func testDuplicateSavedOrderDoesNotTrap() {
        XCTAssertEqual(CardOrder.sorted(["codex:a", "deepseek:b"], by: ["deepseek:b", "codex:a", "deepseek:b"]), ["deepseek:b", "codex:a"])
    }
}

/// Routes Antigravity's three calls; `models == nil` simulates a transport failure on that call.
struct RoutedTransport: HTTPTransport {
    let models: (Data, Int)?
    let assist: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        if path.contains("token") { return (Data(#"{"access_token":"ya29.test"}"#.utf8), 200) }
        if path.contains("loadCodeAssist") { return (assist, 200) }
        guard let models else { throw URLError(.notConnectedToInternet) }
        return models
    }
}

actor CountingTransport: HTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) { count += 1; return (Data(), 500) }
}
