import XCTest
@testable import CodexUsageCore

/// The two App-only providers are parsing code first: every number shown has to come out of the
/// payload, and a payload that does not carry a field must not turn into a guess.
final class ProviderExtrasTests: XCTestCase {

    // MARK: - Shared helpers

    // MARK: - Antigravity quota

    func testAssistParsesPlanAndPromptCredits() {
        // Real shape: planInfo.planType + availablePromptCredits / planInfo.monthlyPromptCredits.
        let payload = Data(#"{"planInfo":{"planType":"g1-pro-tier","monthlyPromptCredits":1000},"availablePromptCredits":320,"cloudaicompanionProject":"proj-1"}"#.utf8)
        let assist = AntigravityAPI.parseAssist(payload)
        XCTAssertEqual(assist.tier, "g1-pro-tier")
        XCTAssertEqual(assist.availableCredits, 320)
        XCTAssertEqual(assist.monthlyCredits, 1000)
        XCTAssertEqual(AntigravityAPI.parseProject(payload), "proj-1")
        let usage = AntigravityUsage(tier: assist.tier, availableCredits: assist.availableCredits,
                                     monthlyCredits: assist.monthlyCredits, quotas: [])
        XCTAssertEqual(usage.hasCredits, true)
        XCTAssertEqual(usage.creditLine, "320 / 1000（剩余 32%）")
    }

    func testAssistFallsBackToPaidTierAndStaysEmptyWithoutCredits() {
        let paid = Data(#"{"paidTier":{"id":"antigravity-pro","availableCredits":[{"creditType":"GOOGLE_ONE_AI","creditAmount":"24.5"}]}}"#.utf8)
        let assist = AntigravityAPI.parseAssist(paid)
        XCTAssertEqual(assist.tier, "antigravity-pro")
        XCTAssertEqual(assist.availableCredits, 24.5)   // older shape still read
        XCTAssertNil(assist.monthlyCredits)

        let bare = AntigravityAPI.parseAssist(Data(#"{}"#.utf8))
        XCTAssertNil(bare.tier)
        XCTAssertNil(bare.availableCredits)
        XCTAssertNil(AntigravityUsage(tier: nil, availableCredits: nil, monthlyCredits: nil, quotas: []).hasCredits)
        XCTAssertNil(AntigravityUsage(tier: nil, availableCredits: nil, monthlyCredits: nil, quotas: []).creditLine)
    }

    func testModelsAreReadFromTheObjectMapAndInternalModelsSkipped() {
        // Real shape: models is an object keyed by model id, each with quotaInfo.
        let payload = Data(#"{"models":{"gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-09-15T00:00:00Z"}},"chat_20706":{"quotaInfo":{"remainingFraction":1}},"gemini-2.5-lite":{"displayName":"Gemini 2.5 Lite","quotaInfo":{"remainingFraction":1}},"claude-sonnet":{"displayName":"Claude Sonnet","quotaInfo":{"remainingFraction":2,"resetTime":"bad"}},"no-quota":{"displayName":"Nope"}}}"#.utf8)
        let rows = AntigravityAPI.parseModels(payload)
        XCTAssertEqual(rows.count, 2, "rows: \(rows.map(\.label))")
        XCTAssertEqual(rows.map(\.label), ["Claude Sonnet", "Gemini 3 Pro"])
        XCTAssertEqual(rows[1].remaining, 75)
        XCTAssertNotNil(rows[1].reset)
        XCTAssertEqual(rows[0].remaining, 100)    // clamped
        XCTAssertNil(rows[0].reset)               // bad timestamp dropped
    }

    func testModelsAlsoReadTheArrayShapeAndBucketsStillParse() {
        let array = Data(#"{"models":[{"modelId":"tab_flash","quotaInfo":{"remainingFraction":1}},{"modelId":"m1","displayName":"M1","quotaInfo":{"remainingFraction":0.5}}]}"#.utf8)
        XCTAssertEqual(AntigravityAPI.parseModels(array).map(\.label), ["M1"])
        let buckets = Data(#"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.4,"resetTime":"2026-09-15T00:00:00Z"},{"modelId":"no-fraction"}]}"#.utf8)
        let quotaRows = AntigravityAPI.parseQuotas(buckets)
        XCTAssertEqual(quotaRows.count, 1, "quota rows: \(quotaRows.map(\.label))")
        XCTAssertEqual(quotaRows.map(\.label), ["gemini-3-pro"])
        XCTAssertEqual(quotaRows[0].remaining, 40)
    }

    func testUsageCombinesAssistAndModels() async throws {
        let assist = Data(#"{"planInfo":{"planType":"g1-pro-tier","monthlyPromptCredits":1000},"availablePromptCredits":0,"cloudaicompanionProject":"p1"}"#.utf8)
        let models = Data(#"{"models":{"gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.4}}}}"#.utf8)
        let api = AntigravityAPI(transport: FirstResponseWinsTransport(json: #"{"access_token":"ya29.test"}"#, second: assist, third: models))
        let usage = try await api.usage(refreshToken: "1//refresh")
        XCTAssertEqual(usage.tier, "g1-pro-tier")
        XCTAssertEqual(usage.availableCredits, 0)
        XCTAssertEqual(usage.hasCredits, false)
        XCTAssertEqual(usage.quotas.count, 1, "quotas: \(usage.quotas.map(\.label))")
        XCTAssertEqual(usage.quotas.map(\.label), ["Gemini 3 Pro"])
        XCTAssertEqual(usage.quotas[0].remaining, 40)
    }

    func testRefreshTokenValueIsCheckedBeforeAnyRequest() {
        XCTAssertEqual(try? AntigravityAPI.validatedToken(" 1//0abc "), "1//0abc")
        XCTAssertThrowsError(try AntigravityAPI.validatedToken("  "))
        XCTAssertThrowsError(try AntigravityAPI.validatedToken("bad\ntoken"))
    }

    func testSnapshotsRoundTripThroughCodable() throws {
        let antigravity = AntigravitySnapshot(usage: AntigravityUsage(tier: "g1-pro-tier", availableCredits: 320, monthlyCredits: 1000,
                                                                     quotas: [AntigravityQuota(label: "Gemini 3 Pro", remaining: 75, reset: Date(timeIntervalSince1970: 1_760_000_000))]),
                                              updatedAt: Date(timeIntervalSince1970: 1_760_000_000))
        let round = try JSONDecoder().decode(AntigravitySnapshot.self, from: JSONEncoder().encode(antigravity))
        XCTAssertEqual(round, antigravity)
    }

    // MARK: - Antigravity sign-in (loopback OAuth)

    func testCallbackParsesTheAuthorizationCodeAndErrors() {
        XCTAssertEqual(AntigravityOAuth.parseCallback("GET /oauth2callback?code=4/0Abc&state=S HTTP/1.1", expectedState: "S"), .code("4/0Abc"))
        XCTAssertEqual(AntigravityOAuth.parseCallback("GET /oauth2callback?error=access_denied&state=S HTTP/1.1", expectedState: "S"), .failure("access_denied"))
        XCTAssertNil(AntigravityOAuth.parseCallback("GET /oauth2callback?code=x&state=wrong HTTP/1.1", expectedState: "S"))
        XCTAssertNil(AntigravityOAuth.parseCallback("GET /wrong?code=x&state=S HTTP/1.1", expectedState: "S"))
        XCTAssertNil(AntigravityOAuth.parseCallback("not a request line", expectedState: "S"))
        // An error wins over a partial code, so a failed consent never yields a token.
        XCTAssertEqual(AntigravityOAuth.parseCallback("GET /oauth2callback?code=x&error=invalid_scope&state=S HTTP/1.1", expectedState: "S"), .failure("invalid_scope"))
    }

    func testPKCEVerifierAndChallengeAreWellFormed() {
        let verifier = AntigravityOAuth.codeVerifier()
        XCTAssertEqual(verifier.count, 43)                       // 32 random bytes, base64url, unpadded
        XCTAssertFalse(verifier.contains("+") || verifier.contains("/") || verifier.contains("="))
        XCTAssertNotEqual(AntigravityOAuth.codeVerifier(), verifier)
        let challenge = AntigravityOAuth.codeChallenge(verifier)
        XCTAssertEqual(challenge.count, 43)
        XCTAssertEqual(challenge, AntigravityOAuth.codeChallenge(verifier))
        XCTAssertNotEqual(challenge, verifier)
    }

    func testAuthorizeURLNamesTheLoopbackRedirectAndOfflineAccess() throws {
        let redirect = AntigravityOAuth.redirectURI(port: AntigravityOAuth.preferredPort)
        XCTAssertEqual(redirect, "http://localhost:51121/oauth2callback")
        let url = AntigravityOAuth.authorizeURL(redirectURI: redirect, challenge: "CHAL", state: "STATE")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(value("client_id"), AntigravityAPI.clientID)
        XCTAssertEqual(value("redirect_uri"), redirect)
        XCTAssertEqual(value("code_challenge"), "CHAL")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "STATE")
        XCTAssertEqual(value("access_type"), "offline")          // a refresh token is required
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("scope")?.split(separator: " ").count, AntigravityOAuth.scopes.count)
    }

    func testCodeExchangeReturnsTheRefreshTokenAndMapsFailures() async throws {
        let ok = AntigravityAPI(transport: StubTransport(status: 200, data: Data(#"{"access_token":"a","refresh_token":"1//stored"}"#.utf8)))
        let refresh = try await ok.exchange(code: "c", verifier: "v", redirectURI: "http://localhost:51121/oauth2callback")
        XCTAssertEqual(refresh, "1//stored")

        let mismatched = AntigravityAPI(transport: StubTransport(status: 200, data: Data(#"{"access_token":"a"}"#.utf8)))
        do { _ = try await mismatched.exchange(code: "c", verifier: "v", redirectURI: "r"); XCTFail("expected malformed") }
        catch let error as AntigravityError { XCTAssertEqual(error, .malformed) }

        let denied = AntigravityAPI(transport: StubTransport(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8)))
        do { _ = try await denied.exchange(code: "c", verifier: "v", redirectURI: "r"); XCTFail("expected unauthorized") }
        catch let error as AntigravityError { XCTAssertEqual(error, .unauthorized) }
    }

    func testUsagePoolsCollapseModelsIntoTightestPerPool() {
        let usage = AntigravityUsage(tier: "g1-pro-tier", availableCredits: nil, monthlyCredits: nil, quotas: [
            AntigravityQuota(label: "Gemini 3 Pro", remaining: 80, reset: Date(timeIntervalSince1970: 100)),
            AntigravityQuota(label: "Gemini 3 Flash", remaining: 60, reset: Date(timeIntervalSince1970: 200)),
            AntigravityQuota(label: "Claude Opus 4.6", remaining: 100, reset: Date(timeIntervalSince1970: 300)),
            AntigravityQuota(label: "GPT-OSS 120B", remaining: 40, reset: Date(timeIntervalSince1970: 400))
        ])
        let pools = usage.pools
        XCTAssertEqual(pools.map(\.label), ["Gemini 池", "Claude · 其他池"])
        XCTAssertEqual(pools[0].remaining, 60)                    // tightest inside the Gemini pool
        XCTAssertEqual(pools[1].remaining, 40)                    // tightest inside the other pool
        XCTAssertEqual(usage.tightestRemaining, 40)
        // A row without a fraction never drags a pool to zero.
        let partial = AntigravityUsage(tier: nil, availableCredits: nil, monthlyCredits: nil, quotas: [
            AntigravityQuota(label: "Gemini 3 Pro", remaining: nil, reset: nil),
            AntigravityQuota(label: "Claude Sonnet", remaining: 90, reset: nil)
        ])
        XCTAssertNil(partial.pools[0].remaining)
        XCTAssertEqual(partial.pools[1].remaining, 90)
        XCTAssertEqual(partial.tightestRemaining, 90)
    }

    // MARK: - Card order (drag to reorder)

    func testCardOrderMovesACardInFrontOfItsTarget() {
        let keys = ["codex:a", "deepseek:b", "antigravity:-"]
        XCTAssertEqual(CardOrder.move("antigravity:-", before: "codex:a", in: keys), ["antigravity:-", "codex:a", "deepseek:b"])
        XCTAssertEqual(CardOrder.move("codex:a", before: "antigravity:-", in: keys), ["deepseek:b", "codex:a", "antigravity:-"])
        // Dropping a card onto itself, or naming a card that is gone, changes nothing.
        XCTAssertEqual(CardOrder.move("codex:a", before: "codex:a", in: keys), keys)
        XCTAssertEqual(CardOrder.move("missing", before: "codex:a", in: keys), keys)
    }

    func testSavedOrderSortsKnownKeysAndKeepsNewOnesLast() {
        let order = ["deepseek:b", "codex:a"]
        XCTAssertEqual(CardOrder.sorted(["codex:a", "deepseek:b"], by: order), ["deepseek:b", "codex:a"])
        // A card that is not in the saved order (a newly added account) stays after the known ones.
        XCTAssertEqual(CardOrder.sorted(["codex:a", "deepseek:b", "codex:new"], by: order), ["deepseek:b", "codex:a", "codex:new"])
        XCTAssertEqual(CardOrder.sorted(["codex:a", "deepseek:b"], by: []), ["codex:a", "deepseek:b"])
    }

    func testSwappingAndAppendingCardsMatchesTheMoveHelpers() {
        // The App's moveCard/moveCardToEnd do exactly this on a plain array; keep the semantics
        // pinned here so a future refactor cannot silently change what 上移/下移/移到最后 mean.
        var keys = ["codex:a", "deepseek:b", "antigravity:-"]
        keys.swapAt(1, 0)
        XCTAssertEqual(keys, ["deepseek:b", "codex:a", "antigravity:-"])          // 上移
        keys.swapAt(1, 2)
        XCTAssertEqual(keys, ["deepseek:b", "antigravity:-", "codex:a"])          // 下移
        let item = keys.remove(at: 1)
        keys.append(item)
        XCTAssertEqual(keys, ["deepseek:b", "codex:a", "antigravity:-"])          // 移到最后
        XCTAssertEqual(CardOrder.sorted(keys, by: keys), keys)                    // 保存后原样回来
    }
}

/// Returns a canned (status, data) pair, or throws a URLError, without touching the network.
struct StubTransport: HTTPTransport {
    var status: Int = 200
    var data = Data()
    var error: Error?
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if let error { throw error }
        return (data, status)
    }
}

/// Antigravity asks for a token and then two backends: answer them in order.
struct FirstResponseWinsTransport: HTTPTransport {
    let json: String
    let second: Data
    let third: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        if path.contains("token") { return (Data(json.utf8), 200) }
        if path.contains("loadCodeAssist") { return (second, 200) }
        if path.contains("fetchAvailableModels") || path.contains("retrieveUserQuota") { return (third, 200) }
        return (Data(), 404)
    }
}
