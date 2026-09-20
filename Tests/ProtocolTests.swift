import XCTest
@testable import CodexUsageCore

actor ScriptedTransport: HTTPTransport {
    var replies: [(String, Int)]
    var requests: [URLRequest] = []
    init(_ replies: [(String, Int)]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw ServiceError.malformed }
        let reply = replies.removeFirst()
        return (Data(reply.0.utf8), reply.1)
    }
}
struct CancelledBalanceTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        throw URLError(.cancelled)
    }
}
final class ProtocolTests: XCTestCase {
    func testDeepSeekURLCancellationIsNotANetworkFailure() async {
        do {
            _ = try await DeepSeekAPI(transport: CancelledBalanceTransport()).balance(key: "synthetic")
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Cancellation was mapped to \(error)") }
    }

    func testAlreadyCancelledDeepSeekDoesNotSendRequest() async {
        let transport = ScriptedTransport([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DeepSeekAPI(transport: transport).balance(key: "synthetic")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testDeepSeekOfficialBalanceDecimalsAndCurrency() async throws {
        let transport = ScriptedTransport([(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0.123456789","granted_balance":"0.003456789","topped_up_balance":"0.12","future":42}],"future":true}"#, 200)])
        let value = try await DeepSeekAPI(transport: transport).balance(key: "synthetic-only-key")
        XCTAssertEqual(value.balanceInfos.first?.total, Decimal(string: "0.123456789"))
        XCTAssertEqual(value.balanceInfos.first?.currency, "USD")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-only-key")
        XCTAssertNil(requests.first?.httpBody)
    }
    func testDeepSeekRejectsMalformedAndMapsErrorsWithoutBody() async throws {
        for status in [401, 403, 429, 500] {
            let t = ScriptedTransport([("synthetic-secret-never-display", status)])
            do { _ = try await DeepSeekAPI(transport: t).balance(key: "fixture"); XCTFail("must fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-secret")) }
        }
        for body in ["{}", #"{"is_available":true,"balance_infos":[]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12oops","granted_balance":"0","topped_up_balance":"0"}]}"#] {
            do { _ = try await DeepSeekAPI(transport: ScriptedTransport([(body, 200)])).balance(key: "fixture"); XCTFail("must fail") }
            catch { XCTAssertTrue(error is DeepSeekError) }
        }
        let t = ScriptedTransport([])
        do { _ = try await DeepSeekAPI(transport: t).balance(key: "a\nb"); XCTFail("must fail") } catch {}
        let requests = await t.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testDeepSeekKeychainIsolationAndStaleCacheOnFailure() async throws {
        let id = "test-ds-" + UUID().uuidString
        defer { try? DeepSeekStore.remove(id) }
        try DeepSeekStore.saveKey("synthetic-key-only", id: id)
        XCTAssertEqual(try DeepSeekStore.key(id), "synthetic-key-only")
        XCTAssertNil(try SharedStorage.credentials(account: id))
        let body = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"-0.01","granted_balance":"0.02","topped_up_balance":"-0.03"}]}"#
        let service = DeepSeekService(api: DeepSeekAPI(transport: ScriptedTransport([(body, 200), ("secret response", 401)])))
        let snapshot = try await service.refresh(id: id, widget: false)
        XCTAssertEqual(snapshot.balance.balanceInfos.first?.granted, Decimal(string: "0.02"))
        XCTAssertEqual(snapshot.balance.balanceInfos.first?.toppedUp, Decimal(string: "-0.03"))
        XCTAssertFalse(snapshot.balance.isAvailable)
        XCTAssertTrue(snapshot.isStale(now: snapshot.updatedAt.addingTimeInterval(1801)))
        do { _ = try await service.refresh(id: id, widget: false); XCTFail("must fail") } catch {}
        XCTAssertEqual(DeepSeekStore.snapshot(id), snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-key"))
        XCTAssertTrue(WidgetRefreshAttempt.load(id).failed)
        let other = "test-ds-" + UUID().uuidString
        XCTAssertNil(DeepSeekStore.snapshot(other))
        XCTAssertNil(try DeepSeekStore.key(other))
    }
    func testDeepSeekMissingOptionalAmountsRoundTripAndDeniedWidget() async throws {
        let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"18.1234"}]}"#
        let value = try await DeepSeekAPI(transport: ScriptedTransport([(body, 200)])).balance(key: "synthetic")
        XCTAssertNil(value.balanceInfos[0].granted)
        XCTAssertNil(value.balanceInfos[0].toppedUp)
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekBalance.self, from: JSONEncoder().encode(value)), value)
        let transport = ScriptedTransport([(body, 200)])
        do {
            _ = try await DeepSeekService(api: DeepSeekAPI(transport: transport)).refresh(id: "synthetic-denied", widget: true, permission: { false })
            XCTFail("denied widget must not request")
        } catch {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let row = DashboardAccount(id: "synthetic-id", provider: "deepseek", ordinal: 2, credentialGroup: nil)
        XCTAssertEqual(try JSONDecoder().decode(DashboardAccount.self, from: JSONEncoder().encode(row)), row)
        XCTAssertFalse(DashboardStore.canRefresh("synthetic-missing", provider: "deepseek"))
    }
    func testThemeRoundTripDefaultsAndRefreshDeduplication() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThemePreference.load(from: url), .system)
        for theme in ThemePreference.allCases {
            try theme.save(to: url)
            XCTAssertEqual(ThemePreference.load(from: url), theme)
        }
        try Data("invalid".utf8).write(to: url)
        XCTAssertEqual(ThemePreference.load(from: url), .system)
        XCTAssertEqual(RefreshTargets.unique(["a", "a", nil, "b"]), ["a", "b"])
    }
    func decodeCode() throws -> DeviceCode {
        try JSONDecoder().decode(DeviceCode.self, from: Data(#"{"device_auth_id":"device","user_code":"ABCD","interval":1}"#.utf8))
    }
    func credentials() throws -> Credentials {
        try Credentials(response: JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":3600}"#.utf8)), now: Date(timeIntervalSince1970: 100))
    }
    func testPendingPollDoesNotExchangeTokens() async throws {
        for status in [403, 404] {
            let transport = ScriptedTransport([("{}", status)])
            let result = try await AuthAPI(transport: transport).pollOnce(decodeCode())
            XCTAssertNil(result)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.path, "/api/accounts/deviceauth/token")
        }
    }
    func testAuthorizationExchangeUsesPKCEAndExactRedirect() async throws {
        let transport = ScriptedTransport([(#"{"authorization_code":"a+b&c","code_verifier":"verifier","code_challenge":"unused"}"#, 200), (#"{"access_token":"a","refresh_token":"r"}"#, 200)])
        let token = try await AuthAPI(transport: transport).pollOnce(decodeCode())
        XCTAssertEqual(token?.accessToken, "a")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.absoluteString, "https://auth.openai.com/oauth/token")
        let body = String(data: requests[1].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("code=a%2Bb%26c"))
        XCTAssertTrue(body.contains("code_verifier=verifier"))
        XCTAssertTrue(body.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
    }
    func testRefreshPreservesUnrotatedRefreshToken() async throws {
        let transport = ScriptedTransport([(#"{"access_token":"new-access","expires_in":10}"#, 200)])
        let result = try await AuthAPI(transport: transport).refresh(credentials())
        XCTAssertEqual(result.refreshToken, "test-refresh")
        XCTAssertEqual(result.accessToken, "new-access")
        let requests = await transport.requests
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String:String]
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["client_id"], AuthAPI.clientID)
    }
    func testRevokedRefreshRequiresLogin() async throws {
        let transport = ScriptedTransport([("{}", 400)])
        do { _ = try await AuthAPI(transport: transport).refresh(credentials()); XCTFail("Expected loginRequired") }
        catch ServiceError.loginRequired {} catch { XCTFail("Wrong error: \(error)") }
    }
    func testUsageRequestUsesBearerAndAccountID() async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id":"test-account"], "exp": 2000000000] as [String:Any]).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let response = TokenResponse(accessToken: "header.\(payload).signature", refreshToken: "r", idToken: nil, expiresIn: nil)
        let transport = ScriptedTransport([(#"{"rate_limit":null}"#, 200)])
        _ = try await AuthAPI(transport: transport).usage(Credentials(response: response))
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(response.accessToken)")
    }
    func testCancelledLoginDoesNotPoll() async throws {
        let transport = ScriptedTransport([])
        let code = try decodeCode()
        let task = Task { try await Task.sleep(for: .seconds(1)); return try await AuthAPI(transport: transport).complete(code) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
    func testUnexpectedPollStatusIsNotTreatedAsPending() async throws {
        let transport = ScriptedTransport([("{}", 429)])
        do { _ = try await AuthAPI(transport: transport).pollOnce(decodeCode()); XCTFail("Expected HTTP error") }
        catch ServiceError.http(429) {} catch { XCTFail("Wrong error") }
    }
    func testMalformedUsageIsNotZeroQuota() async throws {
        let transport = ScriptedTransport([("<html>WAF</html>", 200)])
        do { _ = try await AuthAPI(transport: transport).usage(credentials()); XCTFail("Expected decoding error") }
        catch is DecodingError {} catch { XCTFail("Wrong error") }
    }
}
