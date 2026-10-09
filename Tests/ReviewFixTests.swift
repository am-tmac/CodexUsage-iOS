import XCTest
import Security
@testable import CodexUsageCore

/// Failure modes found in the 2026-09 code review. Each test pins one way the App could lose a
/// credential, show a guessed number, or accept a login it should reject.
final class ReviewFixTests: XCTestCase {
    override class func setUp() { super.setUp(); TestContainer.install() }
    private var previousContainer: URL?
    private var isolatedContainer: URL?
    override func setUpWithError() throws {
        previousContainer = SharedStorage.containerOverride
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeReview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        isolatedContainer = url
        SharedStorage.containerOverride = url
    }
    override func tearDownWithError() throws {
        SharedStorage.containerOverride = previousContainer
        if let isolatedContainer { try FileManager.default.removeItem(at: isolatedContainer) }
    }

    // MARK: - build 30: legacy cleanup must not erase the current OAuth state

    func testBuild30LegacyCleanupDoesNotDeleteOAuthCacheOrBackoff() throws {
        // This source-policy check intentionally avoids the production Keychain delete target.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Shared/Claude.swift"))
        let body = try XCTUnwrap(source.components(separatedBy: "static func invalidateLegacyCredential").last)
            .components(separatedBy: "static func snapshotURL")[0]
        XCTAssertFalse(body.contains("removeItem"), "Legacy cleanup cannot identify ownership of the shared quota/attempt paths; preserve both")
        XCTAssertFalse(body.contains("snapshotURL()"), "Current OAuth cache is not a migration target")
        XCTAssertFalse(body.contains("WidgetRefreshAttempt.url"), "Current OAuth backoff is not a migration target")
    }

    func testBuild30LegacyCleanupIsIdempotentAndOnlyDeletesTheLegacyCredential() throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 42, reset: nil), sevenDay: nil,
                                  updatedAt: Date(timeIntervalSince1970: 123))
        try ClaudeStore.save(good)
        var attempt = WidgetRefreshAttempt()
        attempt.fail(Date())
        try attempt.save(ClaudeStore.id)
        let snapshotBefore = try Data(contentsOf: ClaudeStore.snapshotURL())
        let attemptBefore = try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id))
        var items = [ClaudeStore.service: Data("synthetic-oauth-record".utf8)]
        var deletedServices: [String] = []
        func delete(_ query: CFDictionary) -> OSStatus {
            let query = query as NSDictionary
            let service = query[kSecAttrService as String] as? String ?? ""
            deletedServices.append(service)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, ClaudeStore.id)
            return items.removeValue(forKey: service) == nil ? errSecItemNotFound : errSecSuccess
        }
        XCTAssertFalse(ClaudeStore.invalidateLegacyCredential(delete: delete), "missing legacy is a no-op")
        XCTAssertEqual(try Data(contentsOf: ClaudeStore.snapshotURL()), snapshotBefore)
        XCTAssertEqual(try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id)), attemptBefore)
        items[ClaudeStore.legacyService] = Data("synthetic-session-cookie".utf8)
        XCTAssertTrue(ClaudeStore.invalidateLegacyCredential(delete: delete), "real legacy entry is removed")
        XCTAssertNil(items[ClaudeStore.legacyService])
        XCTAssertFalse(ClaudeStore.invalidateLegacyCredential(delete: delete), "repeat startup is a no-op")
        XCTAssertEqual(items[ClaudeStore.service], Data("synthetic-oauth-record".utf8))
        XCTAssertEqual(deletedServices, Array(repeating: ClaudeStore.legacyService, count: 3))
        XCTAssertEqual(try Data(contentsOf: ClaudeStore.snapshotURL()), snapshotBefore)
        XCTAssertEqual(try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id)), attemptBefore)
    }

    func testBuild30LegacyDeletionFailurePreservesOAuthState() throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 42, reset: nil), sevenDay: nil, updatedAt: Date())
        try ClaudeStore.save(good)
        var attempt = WidgetRefreshAttempt(); attempt.fail(Date()); try attempt.save(ClaudeStore.id)
        let before = try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id))
        XCTAssertFalse(ClaudeStore.invalidateLegacyCredential(delete: { _ in errSecInteractionNotAllowed }))
        XCTAssertEqual(ClaudeStore.snapshot(), good)
        XCTAssertEqual(try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id)), before)
    }

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

    // MARK: - build 30: forbidden usage is not a token-expiry retry

    func testBuild30ForbiddenUsageNeverRotatesAndKeepsCache() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 37, reset: nil), sevenDay: nil, updatedAt: Date())
        try ClaudeStore.save(good)
        let transport = ScriptedTransport([("synthetic-private-upstream-body", 403),
                                           (#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#, 200), usageReply])
        var saved: [ClaudeCredential] = []
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        do {
            _ = try await claudeService(transport, credential: credential, saved: { saved.append($0) })
                .refresh(widget: false, permission: { true })
            XCTFail("403 must surface denied access instead of rotating")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude 用量访问被拒绝；保留缓存，请在 App 检查账号授权与服务可用性")
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private"))
            XCTAssertFalse(error.localizedDescription.contains("地区"), "403 alone cannot prove a region block")
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertTrue(saved.isEmpty, "no refresh-token exchange or credential write on 403")
        XCTAssertEqual(ClaudeStore.snapshot(), good)
        XCTAssertTrue(WidgetRefreshAttempt.load(ClaudeStore.id).failed)
    }

    func testBuild30RepeatedUsage401RotatesOnlyOnce() async throws {
        let transport = ScriptedTransport([("private-first", 401),
                                           (#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#, 200),
                                           ("private-second", 401)])
        var saved: [ClaudeCredential] = []
        let credential = ClaudeCredential(refreshToken: "r1", obtainedAt: Date(), accessToken: "a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        do {
            _ = try await claudeService(transport, credential: credential, saved: { saved.append($0) })
                .refresh(widget: false, permission: { true })
            XCTFail("second 401 must stop")
        } catch let error as ClaudeFailure { XCTAssertEqual(error, .unauthorized) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        XCTAssertEqual(saved.map(\.refreshToken), ["r2"])
    }

    // MARK: - build 30: widget cache fallback is not a successful refresh

    func testBuild30ExpiredWidgetTokenMarksOpenAppWithoutNetworkOrFalseSuccess() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 50, reset: nil), sevenDay: nil,
                                  updatedAt: Date(timeIntervalSince1970: 1))
        try ClaudeStore.save(good)
        let before = try Data(contentsOf: ClaudeStore.snapshotURL())
        let transport = ScriptedTransport([])
        var saves = 0
        let expired = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                       accessExpiresAt: Date().addingTimeInterval(-10))
        let service = claudeService(transport, credential: expired, saved: { _ in saves += 1 })
        let value = try await service.refresh(widget: true, permission: { true })
        XCTAssertEqual(value, good)
        XCTAssertEqual(try Data(contentsOf: ClaudeStore.snapshotURL()), before)
        let attempt = WidgetRefreshAttempt.load(ClaudeStore.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        XCTAssertEqual(object["needsAppRefresh"] as? Bool, true, "persist an explicit open-App state")
        XCTAssertTrue(attempt.failed, "fallback cannot reset failures like a successful usage request")
        XCTAssertNil(attempt.startedAt)
        XCTAssertFalse(attempt.allows(Date()), "keep failure backoff")
        let repeated = try await service.refresh(widget: true, permission: { true })
        XCTAssertEqual(repeated, good)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(saves, 0)
    }

    func testBuild30ExpiredWidgetWithoutCacheClearlyRequiresApp() async throws {
        try? FileManager.default.removeItem(at: ClaudeStore.snapshotURL())
        let transport = ScriptedTransport([])
        let expired = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                       accessExpiresAt: Date().addingTimeInterval(-10))
        let service = claudeService(transport, credential: expired)
        for _ in 0..<2 {
            do { _ = try await service.refresh(widget: true, permission: { true }); XCTFail("must require App") }
            catch { XCTAssertEqual(error.localizedDescription, "Claude 访问授权需要更新，请打开 App 刷新；组件不会续期授权") }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBuild30AppFreshUsageClearsPersistedNeedsRefreshAndOldJSONStillDecodes() async throws {
        let oldJSON = Data(#"{"nextAllowed":1000,"failures":3,"completedAt":900}"#.utf8)
        let old = try JSONDecoder().decode(WidgetRefreshAttempt.self, from: oldJSON)
        XCTAssertEqual(old.failures, 3)
        XCTAssertEqual(old.nextAllowed, Date(timeIntervalSinceReferenceDate: 1000))
        let markedJSON = Data(#"{"nextAllowed":9999999999,"failures":3,"completedAt":900,"needsAppRefresh":true}"#.utf8)
        try markedJSON.write(to: WidgetRefreshAttempt.url(ClaudeStore.id))
        let transport = ScriptedTransport([usageReply])
        let credential = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        // Do not use the helper that deletes attempts: the App must recover this exact record.
        let service = ClaudeService(api: ClaudeAPI(transport: transport),
                                    store: ClaudeCredentialStore(load: { _ in credential }, save: { _, _ in XCTFail("valid access must not rotate") }))
        let value = try await service.refresh(widget: false, permission: { true })
        XCTAssertEqual(value.fiveHour?.remaining, 90)
        let recovered = WidgetRefreshAttempt.load(ClaudeStore.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recovered)) as? [String: Any])
        XCTAssertEqual(object["needsAppRefresh"] as? Bool, false)
        XCTAssertFalse(recovered.failed)
        XCTAssertNil(recovered.startedAt)
    }

    func testBuild30Widget401RequiresAppWithoutRotatingOrDiscardingCache() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 51, reset: nil), sevenDay: nil, updatedAt: Date())
        try ClaudeStore.save(good)
        let transport = ScriptedTransport([("synthetic-denied-body", 401)])
        let credential = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        let value = try await claudeService(transport, credential: credential, saved: { _ in XCTFail("Widget cannot rotate") })
            .refresh(widget: true, permission: { true })
        XCTAssertEqual(value, good)
        let attempt = WidgetRefreshAttempt.load(ClaudeStore.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        XCTAssertEqual(object["needsAppRefresh"] as? Bool, true)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testBuild30AppRenewalClearsWidgetMarkerEvenWhenUsageThenFails() async throws {
        var marked = WidgetRefreshAttempt(); marked.requireAppRefresh(Date(timeIntervalSince1970: 1))
        try marked.save(ClaudeStore.id)
        // Rotation succeeds and is persisted; the usage call after it hits a network failure.
        let transport = ScriptedTransport([(#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#, 200)])
        var saved: [ClaudeCredential] = []
        let expired = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                       accessExpiresAt: Date().addingTimeInterval(-10))
        let service = ClaudeService(api: ClaudeAPI(transport: transport),
                                    store: ClaudeCredentialStore(load: { _ in expired }, save: { value, _ in saved.append(value) }))
        do { _ = try await service.refresh(widget: false, permission: { true }); XCTFail("usage must fail") } catch {}
        XCTAssertEqual(saved.map(\.refreshToken), ["r2"])
        let attempt = WidgetRefreshAttempt.load(ClaudeStore.id)
        XCTAssertFalse(attempt.requiresAppRefresh, "a persisted renewal lets the widget use the new token")
        XCTAssertTrue(attempt.failed, "the failed usage request still counts as a failure")
    }

    func testBuild30AppFailureWithoutRenewalKeepsWidgetMarker() async throws {
        var marked = WidgetRefreshAttempt(); marked.requireAppRefresh(Date(timeIntervalSince1970: 1))
        try marked.save(ClaudeStore.id)
        let transport = ScriptedTransport([]) // usage with a still-valid token fails on the network
        let valid = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                     accessExpiresAt: Date().addingTimeInterval(3600))
        let service = ClaudeService(api: ClaudeAPI(transport: transport),
                                    store: ClaudeCredentialStore(load: { _ in valid }, save: { _, _ in XCTFail("no rotation") }))
        do { _ = try await service.refresh(widget: false, permission: { true }); XCTFail("usage must fail") } catch {}
        XCTAssertTrue(WidgetRefreshAttempt.load(ClaudeStore.id).requiresAppRefresh)
    }

    func testBuild30NeedsRefreshSurvivesFailureAndTimeButSuccessClearsIt() throws {
        let now = Date(timeIntervalSince1970: 1234)
        var attempt = WidgetRefreshAttempt()
        let previousBackoff = now.addingTimeInterval(3600)
        attempt.nextAllowed = previousBackoff
        attempt.requireAppRefresh(now)
        XCTAssertTrue(attempt.requiresAppRefresh)
        XCTAssertEqual(attempt.nextAllowed, previousBackoff, "renewal marker must not shorten existing backoff")
        attempt.fail(now.addingTimeInterval(20))
        XCTAssertTrue(attempt.requiresAppRefresh, "a failed App request is not recovery")
        XCTAssertTrue(attempt.allows(now.addingTimeInterval(86400)))
        XCTAssertTrue(attempt.requiresAppRefresh, "elapsed time cannot renew authorization")
        try attempt.save(ClaudeStore.id)
        XCTAssertTrue(WidgetRefreshAttempt.load(ClaudeStore.id).requiresAppRefresh)
        attempt.succeed(now.addingTimeInterval(30))
        XCTAssertFalse(attempt.requiresAppRefresh)
        XCTAssertFalse(attempt.failed)
    }

    func testBuild30WidgetStillRequiresSharingLeaseAndBackoff() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 62, reset: nil), sevenDay: nil, updatedAt: Date())
        try ClaudeStore.save(good)
        let transport = ScriptedTransport([])
        var reads = 0
        let credential = ClaudeCredential(refreshToken: "synthetic-r1", obtainedAt: Date(), accessToken: "synthetic-a1",
                                          accessExpiresAt: Date().addingTimeInterval(3600))
        let service = ClaudeService(api: ClaudeAPI(transport: transport),
                                    store: ClaudeCredentialStore(load: { _ in reads += 1; return credential }, save: { _, _ in XCTFail("cannot rotate") }))
        do { _ = try await service.refresh(widget: true, permission: { false }); XCTFail("sharing is required") }
        catch let error as ClaudeFailure { XCTAssertEqual(error, .storage) }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(WidgetRefreshAttempt.load(ClaudeStore.id).completedAt)
        let lease = try CredentialLease(account: ClaudeStore.id)
        do { _ = try await service.refresh(widget: true, permission: { true }); XCTFail("held lease is required") }
        catch ServiceError.busy {} catch { XCTFail("unexpected lease failure: \(error)") }
        withExtendedLifetime(lease) {}
        XCTAssertEqual(reads, 0)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBuild30WidgetBackoffRetainsCacheAndDoesNotReadCredentials() async throws {
        let good = ClaudeSnapshot(fiveHour: ClaudeWindow(remaining: 62, reset: nil), sevenDay: nil, updatedAt: Date())
        try ClaudeStore.save(good)
        var attempt = WidgetRefreshAttempt(); attempt.fail(Date()); try attempt.save(ClaudeStore.id)
        let before = try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id))
        let transport = ScriptedTransport([])
        let service = ClaudeService(api: ClaudeAPI(transport: transport), store: ClaudeCredentialStore(
            load: { _ in XCTFail("backoff must run before credential reads"); throw ClaudeFailure.storage },
            save: { _, _ in XCTFail("backoff must not write credentials") }))
        let result = try await service.refresh(widget: true, permission: { true })
        XCTAssertEqual(result, good)
        XCTAssertEqual(try Data(contentsOf: WidgetRefreshAttempt.url(ClaudeStore.id)), before)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBuild30ClaudeWidgetWiringShowsOpenAppAndStaleCache() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let widget = try String(contentsOf: root.appendingPathComponent("Widget/CodexUsageWidget.swift"))
        let views = try String(contentsOf: root.appendingPathComponent("Shared/UsageViews.swift"))
        let compact = try XCTUnwrap(views.components(separatedBy: "struct ClaudeCompactView: View {").last)
            .components(separatedBy: "struct CompactUsageView: View {")[0]
        XCTAssertTrue(widget.contains("needsAppRefresh"), "column must remove refresh permission when App renewal is required")
        XCTAssertTrue(widget.contains("打开 App 更新授权"), "open App is distinct from refresh")
        XCTAssertTrue(compact.contains("needsAppRefresh"))
        XCTAssertTrue(compact.contains("snapshot?.isStale()"))
        XCTAssertTrue(compact.contains("无缓存 · 打开 App 更新授权"))
        XCTAssertTrue(views.contains("requiresAppRefresh"), "the intent must skip Claude needing App renewal even in a mixed widget")
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
