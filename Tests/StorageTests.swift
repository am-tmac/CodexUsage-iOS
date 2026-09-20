import XCTest
import Security
@testable import CodexUsageCore
#if os(iOS)
actor HeldUsageTransport: HTTPTransport {
    var count = 0
    var response: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { response?.resume(); response = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume(); started = nil
        }
        return (Data(#"{"rate_limit":null}"#.utf8), 200)
    }
}
actor CancellingRotationTransport: HTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return (Data(#"{"access_token":"unit-cancel-new","refresh_token":"unit-cancel-rotated","expires_in":3600}"#.utf8), 200)
    }
}
final class StorageTests: XCTestCase {
    @MainActor func testUnchangedAccountReloadDoesNotPublishUIUpdates() {
        let model = UsageModel()
        model.reloadAccounts()
        let expectedAccounts = model.accounts
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }

        model.reloadAccounts()
        XCTAssertEqual(updates, 0, "Unchanged cache reload must not invalidate every observing view")

        model.accounts = ["synthetic-missing-account"]
        updates = 0
        model.reloadAccounts()
        XCTAssertEqual(model.accounts, expectedAccounts)
        XCTAssertGreaterThan(updates, 0, "Changed account state must still notify the UI")
    }

    func testFeedbackLifecycleAndLegacyDecoding() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var state = WidgetRefreshAttempt()
        state.begin(now)
        XCTAssertEqual(state.startedAt, now)
        XCTAssertTrue(state.isRefreshing(at: now))
        let copy = try JSONDecoder().decode(WidgetRefreshAttempt.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(copy.isRefreshing(at: now.addingTimeInterval(30)))
        state.succeed(now.addingTimeInterval(2))
        XCTAssertNil(state.startedAt)
        XCTAssertEqual(state.completedAt, now.addingTimeInterval(2))
        XCTAssertFalse(state.failed)
        XCTAssertFalse(state.allows(now.addingTimeInterval(61)))
        let legacy = try JSONDecoder().decode(WidgetRefreshAttempt.self, from: Data(#"{"nextAllowed":0,"failures":0}"#.utf8))
        XCTAssertNil(legacy.startedAt)
        XCTAssertNil(legacy.completedAt)
    }
    func testInterruptedProgressRecoversUnderNextLeaseAndKeepsThrottle() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var state = WidgetRefreshAttempt()
        state.begin(now)
        // Caller owns the lease, so even a fresh marker is an abandoned operation.
        state.recoverInterrupted(now.addingTimeInterval(10))
        XCTAssertNil(state.startedAt)
        XCTAssertTrue(state.failed)
        XCTAssertFalse(state.allows(now.addingTimeInterval(59)))
        XCTAssertTrue(state.allows(now.addingTimeInterval(120)))
        state.begin(now.addingTimeInterval(121))
        state.succeed(now.addingTimeInterval(122))
        XCTAssertFalse(state.failed)
    }
    func testFailureAndStaleProgressClearWithoutLosingBackoff() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var state = WidgetRefreshAttempt()
        state.begin(now)
        XCTAssertFalse(state.isRefreshing(at: now.addingTimeInterval(120)))
        XCTAssertFalse(state.isRefreshing(at: now.addingTimeInterval(-1)))
        state.fail(now.addingTimeInterval(1))
        XCTAssertNil(state.startedAt)
        XCTAssertEqual(state.completedAt, now.addingTimeInterval(1))
        XCTAssertTrue(state.failed)
        XCTAssertFalse(state.allows(now.addingTimeInterval(300)))
    }
    func testPersistedProgressDuringFetchAndConcurrentTapDoesNotDuplicateRequest() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        try await UsageService.shared.install(Credentials(response: TokenResponse(accessToken: "unit-progress", refreshToken: "unit-r", idToken: nil, expiresIn: 3600)))
        let id = try XCTUnwrap(SharedStorage.selectedAccount())
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(id))
        let transport = HeldUsageTransport()
        let service = UsageService(api: AuthAPI(transport: transport))
        let first = Task { try await service.refresh(account: id, widget: true, permission: { true }) }
        await transport.waitUntilStarted()
        let running = WidgetRefreshAttempt.load(id)
        XCTAssertTrue(running.isRefreshing(at: Date()))
        do { _ = try await service.refresh(account: id, widget: true, permission: { true }); XCTFail("Expected busy") }
        catch ServiceError.busy {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(WidgetRefreshAttempt.load(id).startedAt, running.startedAt)
        await transport.finish()
        let result = try await first.value
        let done = WidgetRefreshAttempt.load(id)
        XCTAssertNil(done.startedAt)
        XCTAssertNotNil(done.completedAt)
        XCTAssertFalse(done.failed)
        let cached = try await service.refresh(account: id, widget: true, permission: { true })
        XCTAssertEqual(cached.updatedAt, result.updatedAt)
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }
    func testAbandonedProgressRecoversWithoutExtraRequestWhenLeaseIsRegained() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        try await UsageService.shared.install(Credentials(response: TokenResponse(accessToken: "unit-abandoned", refreshToken: "unit-r", idToken: nil, expiresIn: 3600)))
        let id = try XCTUnwrap(SharedStorage.selectedAccount())
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(id))
        // An extension killed mid-fetch leaves a persisted start marker but releases the flock.
        var abandoned = WidgetRefreshAttempt.load(id)
        abandoned.begin(Date())
        try abandoned.save(id)
        XCTAssertTrue(WidgetRefreshAttempt.load(id).isRefreshing(at: Date()))
        let transport = ScriptedTransport([])
        let service = UsageService(api: AuthAPI(transport: transport))
        do {
            _ = try await service.refresh(account: id, widget: true, permission: { true })
            XCTFail("Expected preserved throttle")
        } catch ServiceError.busy {} catch { XCTFail("Unexpected \(error)") }
        // Regaining the exclusive lease proves no live writer: the stale marker must clear.
        let recovered = WidgetRefreshAttempt.load(id)
        XCTAssertNil(recovered.startedAt)
        XCTAssertNotNil(recovered.completedAt)
        XCTAssertTrue(recovered.failed)
        XCTAssertFalse(recovered.isRefreshing(at: Date()))
        XCTAssertFalse(recovered.allows(Date()))
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
    func testCancellationAfterCompletedRotationPersistsTokenAndReleasesLock() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        try await UsageService.shared.install(Credentials(response: TokenResponse(accessToken: "unit-expired", refreshToken: "unit-r", idToken: nil, expiresIn: -1)))
        let id = try XCTUnwrap(SharedStorage.selectedAccount())
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(id))
        let transport = CancellingRotationTransport()
        let service = UsageService(api: AuthAPI(transport: transport))
        let task = Task { try await service.refresh(account: id, widget: true, permission: { true }) }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let count = await transport.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try SharedStorage.credentials(account: id)?.refreshToken, "unit-cancel-rotated")
        XCTAssertNil(SharedStorage.snapshot(account: id))
        XCTAssertNoThrow(try CredentialLease(account: id))
    }
    func testWidgetRevokeStopsAfterRotationButPreservesAccounts() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        let first = try Credentials(response: TokenResponse(accessToken: "unit-old", refreshToken: "unit-old-r", idToken: nil, expiresIn: -1))
        let second = try Credentials(response: TokenResponse(accessToken: "unit-other", refreshToken: "unit-other-r", idToken: nil, expiresIn: 3600))
        try await UsageService.shared.install(first); try await UsageService.shared.install(second)
        let ids = try SharedStorage.accountIDs()
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(ids[0]))
        let transport = ScriptedTransport([(#"{"access_token":"unit-new","refresh_token":"unit-rotated","expires_in":3600}"#, 200)])
        let service = UsageService(api: AuthAPI(transport: transport))
        var checks = 0
        do {
            _ = try await service.refresh(account: ids[0], widget: true, permission: { checks += 1; return checks <= 3 })
            XCTFail("Expected revoke")
        } catch ServiceError.storage {} catch { XCTFail("Unexpected \(error)") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try SharedStorage.credentials(account: ids[0])?.refreshToken, "unit-rotated")
        XCTAssertEqual(try SharedStorage.credentials(account: ids[1])?.refreshToken, "unit-other-r")
        XCTAssertEqual(try SharedStorage.accountIDs(), ids)
        XCTAssertNoThrow(try CredentialLease(account: ids[0]))
    }
    func testWidgetDeniedConsentStartsNoRequest() async throws {
        let transport = ScriptedTransport([])
        let service = UsageService(api: AuthAPI(transport: transport))
        do { _ = try await service.refresh(account: "denied", widget: true, permission: { false }); XCTFail("Expected denial") }
        catch ServiceError.storage {} catch { XCTFail("Unexpected error") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
    func testWidgetFailureBackoffKeepsSelectedCacheAndPreventsRetry() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        try await UsageService.shared.install(Credentials(response: TokenResponse(accessToken: "unit-backoff", refreshToken: "unit-r", idToken: nil, expiresIn: 3600)))
        let id = try XCTUnwrap(SharedStorage.selectedAccount())
        try? FileManager.default.removeItem(at: WidgetRefreshAttempt.url(id))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rate_limit":null}"#.utf8))
        let cache = UsageSnapshot(usage: usage, updatedAt: Date(timeIntervalSince1970: 42))
        try SharedStorage.save(cache, account: id)
        let transport = ScriptedTransport([("{}", 429)])
        let service = UsageService(api: AuthAPI(transport: transport))
        do { _ = try await service.refresh(account: id, widget: true, permission: { true }); XCTFail("Expected 429") }
        catch ServiceError.http(429) {} catch { XCTFail("Unexpected \(error)") }
        let failedState = WidgetRefreshAttempt.load(id)
        XCTAssertNil(failedState.startedAt)
        XCTAssertNotNil(failedState.completedAt)
        XCTAssertFalse(failedState.isRefreshing(at: Date()))
        let result = try await service.refresh(account: id, widget: true, permission: { true })
        XCTAssertEqual(result.updatedAt, cache.updatedAt)
        XCTAssertTrue(WidgetRefreshAttempt.load(id).failed)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }
    func testCancelledWidgetRefreshDoesNotNetworkOrHoldLock() async throws {
        let transport = ScriptedTransport([])
        let service = UsageService(api: AuthAPI(transport: transport))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.refresh(account: "cancelled", widget: true, permission: { true })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertNoThrow(try CredentialLease(account: "cancelled"))
    }
    func testWidgetBackoffPersistsAndCapsFailures() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var state = WidgetRefreshAttempt()
        XCTAssertTrue(state.allows(now))
        state.begin(now)
        XCTAssertFalse(state.allows(now.addingTimeInterval(59)))
        state.fail(now)
        XCTAssertFalse(state.allows(now.addingTimeInterval(299)))
        XCTAssertTrue(state.allows(now.addingTimeInterval(300)))
        for _ in 0..<20 { state.fail(now) }
        XCTAssertTrue(state.allows(now.addingTimeInterval(3600)))
        let copy = try JSONDecoder().decode(WidgetRefreshAttempt.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(copy.allows(now))
    }
    func testExplicitWidgetRouteRetainsOriginalNamespaceAndAccounts() {
        let app = StorageRouting(sharedURL: nil, authorizedGroup: nil, isWidget: false)
        let widget = StorageRouting(sharedURL: URL(fileURLWithPath: "/shared"), authorizedGroup: "YOURTEAMID.*", isWidget: true)
        XCTAssertEqual(app.query()[kSecAttrService as String] as? String, widget.query()[kSecAttrService as String] as? String)
        XCTAssertEqual(widget.query()[kSecAttrAccessGroup as String] as? String, "YOURTEAMID.*")
    }
    func testConsentRequiresExactGroupAndCurrentConnectivity() throws {
        let consent = WidgetRefreshConsent(group: "YOURTEAMID.*", handshakeID: "session")
        XCTAssertTrue(consent.permits(group: "YOURTEAMID.*", handshakeID: "session", connected: true))
        XCTAssertFalse(consent.permits(group: "YOURTEAMID.shared", handshakeID: "session", connected: true))
        XCTAssertFalse(consent.permits(group: "YOURTEAMID.*", handshakeID: "new", connected: true))
        XCTAssertFalse(consent.permits(group: "YOURTEAMID.*", handshakeID: "session", connected: false))
        XCTAssertEqual(try JSONDecoder().decode(WidgetRefreshConsent.self, from: JSONEncoder().encode(consent)).group, consent.group)
    }
    func testCacheOnlyWidgetReadsAppSnapshotWithoutKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = StorageRouting(sharedURL: root, authorizedGroup: nil, isWidget: false)
        let widget = StorageRouting(sharedURL: root, authorizedGroup: nil, isWidget: true)
        let appURL = try app.cacheContainer(localURL: root.appendingPathComponent("private-app"))
        let widgetURL = try widget.cacheContainer(localURL: root.appendingPathComponent("private-widget"))
        XCTAssertEqual(appURL, root)
        XCTAssertEqual(widgetURL, appURL)
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rate_limit":{"primary_window":{"used_percent":25}}}"#.utf8))
        let snapshot = UsageSnapshot(usage: usage, updatedAt: Date(timeIntervalSince1970: 123456))
        try JSONEncoder().encode(snapshot).write(to: appURL.appendingPathComponent("usage.json"))
        let data = try Data(contentsOf: widgetURL.appendingPathComponent("usage.json"))
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data).usage.rateLimit?.primaryWindow?.remaining, 75)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data).updatedAt, snapshot.updatedAt)
        XCTAssertThrowsError(try widget.requireAccess())
        XCTAssertNil(app.query()[kSecAttrAccessGroup as String])
    }
    func testCacheSelectionAndRefreshPermissionDoNotRequirePrivateCredentials() throws {
        let state = WidgetCacheState(account: "second", credentialGroup: nil)
        XCTAssertEqual(try JSONDecoder().decode(WidgetCacheState.self, from: JSONEncoder().encode(state)).account, "second")
        XCTAssertFalse(state.allowsRefresh(using: StorageRouting(sharedURL: URL(fileURLWithPath: "/shared"), authorizedGroup: "TEAM.shared", isWidget: true)))
        let shared = WidgetCacheState(account: "first", credentialGroup: "TEAM.shared")
        XCTAssertTrue(shared.allowsRefresh(using: StorageRouting(sharedURL: URL(fileURLWithPath: "/shared"), authorizedGroup: "TEAM.shared", isWidget: true)))
        XCTAssertFalse(shared.allowsRefresh(using: StorageRouting(sharedURL: URL(fileURLWithPath: "/shared"), authorizedGroup: "OTHER.shared", isWidget: true)))
        XCTAssertFalse(shared.allowsRefresh(using: StorageRouting(sharedURL: nil, authorizedGroup: "TEAM.shared", isWidget: true)))
    }
    func testObservedWildcardIsOpaqueAndNeverExpanded() {
        var tried: [String] = []
        XCTAssertEqual(SharedStorage.authorizedGroup(configured: "OLD.shared", actualDefaultGroup: "YOURTEAMID.*", suffix: "shared", authorize: { tried.append($0); return $0 == "YOURTEAMID.*" }), "YOURTEAMID.*")
        XCTAssertEqual(tried, ["OLD.shared", "YOURTEAMID.*"])
        XCTAssertEqual(SharedStorage.authorizedGroup(configured: "YOURTEAMID.*", actualDefaultGroup: "YOURTEAMID.*", suffix: "shared", authorize: { $0 == "YOURTEAMID.*" }), "YOURTEAMID.*")
    }
    func testCacheDefaultNeverPublishesProbedGroupAsCredentialPermission() {
        XCTAssertNil(SharedStorage.consent)
        XCTAssertNil(SharedStorage.permittedGroup)
        XCTAssertFalse(SharedStorage.widgetCanRefresh)
        XCTAssertNil(SharedStorage.routing.query()[kSecAttrAccessGroup as String])
    }
    func testCrossProcessHandshakeRejectsSeparateNamespaces() throws {
        var appItems: [String: Data] = [:]
        var widgetItems: [String: Data] = [:]
        let session = ProbeHandshake(group: "YOURTEAMID.*")
        let challenge = Data(UUID().uuidString.utf8)
        appItems[session.appAccount] = challenge
        XCTAssertFalse(try session.widgetRespond(read: { widgetItems[$0] }, write: { widgetItems[$0] = $1 }))
        XCTAssertFalse(try session.appConfirmed(read: { appItems[$0] }))
        // Both local self-probes succeeding cannot prove shared visibility.
        widgetItems["own-probe"] = Data("success".utf8)
        XCTAssertFalse(try session.appConfirmed(read: { appItems[$0] }))
        var shared = appItems
        XCTAssertTrue(try session.widgetRespond(read: { shared[$0] }, write: { shared[$0] = $1 }))
        XCTAssertTrue(try session.appConfirmed(read: { shared[$0] }))
        shared[session.widgetAccount] = Data("wrong-response".utf8)
        XCTAssertFalse(try session.appConfirmed(read: { shared[$0] }))
    }
    func testSafeDiagnosticsShowIndependentCapabilitiesAndStatuses() {
        let report = StorageDiagnostics(configuredAppGroup: "group.test", configuredKeychainGroup: "TEAM.shared", containerAvailable: true, defaultProbeStatus: 0, observedDefaultGroup: "TEAM.*", probes: ["TEAM.shared": -34018], selectedGroup: nil, isWidget: false)
        XCTAssertTrue(report.text.contains("-34018"))
        XCTAssertTrue(report.text.contains("TEAM.*"))
        XCTAssertTrue(report.text.contains("缓存共享"))
        XCTAssertTrue(report.text.contains("group.test"))
    }
    func testMissingAppGroupFallsBackToLocalApplicationSupport() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertEqual(try SharedStorage.container(sharedURL: nil, localURL: local), local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }
    func testUnauthorizedSharedKeychainFallsBackWithoutAccessGroup() {
        XCTAssertNil(SharedStorage.authorizedGroup(configured: "OLD.shared", actualDefaultGroup: "NEW.app", suffix: "shared", authorize: { _ in false }))
    }
    func testNoInferredConcreteChildGroup() {
        XCTAssertNil(SharedStorage.authorizedGroup(configured: "OLD.shared", actualDefaultGroup: "NEW.app", suffix: "shared", authorize: { $0 == "NEW.shared" }))
        XCTAssertEqual(SharedStorage.authorizedGroup(configured: "OLD.shared", actualDefaultGroup: "NEW.app", suffix: "shared", authorize: { $0 == "OLD.shared" }), "OLD.shared")
    }
    func testPrivateRoutingOmitsAccessGroupAndWidgetRefusesPrivateLogin() throws {
        let local = StorageRouting(sharedURL: nil, authorizedGroup: "TEAM.shared", isWidget: false)
        XCTAssertNil(local.query()[kSecAttrAccessGroup as String])
        XCTAssertFalse(local.isShared)
        XCTAssertNoThrow(try local.requireAccess())
        let denied = StorageRouting(sharedURL: URL(fileURLWithPath: "/unused"), authorizedGroup: nil, isWidget: true)
        XCTAssertThrowsError(try denied.requireAccess())
        let shared = StorageRouting(sharedURL: URL(fileURLWithPath: "/unused"), authorizedGroup: "TEAM.shared", isWidget: true)
        XCTAssertEqual(shared.query()[kSecAttrAccessGroup as String] as? String, "TEAM.shared")
        XCTAssertNoThrow(try shared.requireAccess())
    }
    func testSecondAccountLoginDoesNotReplaceFirst() async throws {
        guard try SharedStorage.credentials() == nil else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        let first = try Credentials(response: TokenResponse(accessToken: "unit-first", refreshToken: "unit-first-refresh", idToken: nil, expiresIn: 3600))
        let second = try Credentials(response: TokenResponse(accessToken: "unit-second", refreshToken: "unit-second-refresh", idToken: nil, expiresIn: 3600))
        try await UsageService.shared.install(first)
        try await UsageService.shared.install(second)
        XCTAssertEqual(try SharedStorage.credentials()?.accessToken, "unit-first")
    }
    func testAccountsHaveIsolatedCachesLocksRefreshAndRemoval() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        let a = try Credentials(response: TokenResponse(accessToken: "unit-a", refreshToken: "unit-ra", idToken: nil, expiresIn: 3600))
        let b = try Credentials(response: TokenResponse(accessToken: "unit-b", refreshToken: "unit-rb", idToken: nil, expiresIn: 3600))
        try await UsageService.shared.install(a)
        try await UsageService.shared.install(b)
        let ids = try SharedStorage.accountIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try SharedStorage.credentials(account: ids[1])?.refreshToken, "unit-rb")
        let lease = try CredentialLease(account: ids[0])
        XCTAssertNoThrow(try CredentialLease(account: ids[1]))
        XCTAssertThrowsError(try CredentialLease(account: ids[0]))
        withExtendedLifetime(lease) {}
        let transport = ScriptedTransport([(#"{"rate_limit":{"primary_window":{"used_percent":20}}}"#, 200)])
        let service = UsageService(api: AuthAPI(transport: transport))
        _ = try await service.refresh(account: ids[1])
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer unit-b")
        XCTAssertNil(SharedStorage.snapshot(account: ids[0]))
        XCTAssertEqual(SharedStorage.snapshot(account: ids[1])?.usage.rateLimit?.primaryWindow?.remaining, 80)
        try SharedStorage.selectWidgetAccount(ids[1])
        XCTAssertEqual(SharedStorage.selectedAccount(), ids[1])
        XCTAssertEqual(SharedStorage.widgetState()?.account, ids[1])
        let sharedFiles = try FileManager.default.contentsOfDirectory(at: SharedStorage.container(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        for file in sharedFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("unit-rb"))
            XCTAssertFalse(text.contains("unit-ra"))
            XCTAssertFalse(text.contains("access_token"))
            XCTAssertFalse(text.contains("refresh_token"))
        }
        try await service.logout(account: ids[1])
        XCTAssertEqual(try SharedStorage.accountIDs(), [ids[0]])
        XCTAssertEqual(try SharedStorage.credentials(account: ids[0])?.accessToken, "unit-a")
        XCTAssertNil(SharedStorage.snapshot(account: ids[1]))
        XCTAssertEqual(SharedStorage.selectedAccount(), ids[0])
        XCTAssertEqual(SharedStorage.widgetState()?.account, ids[0])
    }
    func testPrivateKeychainRoundTripWithoutAnyAccessGroup() throws {
        var q = StorageRouting(sharedURL: nil, authorizedGroup: nil, isWidget: false).query()
        q[kSecAttrAccount as String] = "unit-test-" + UUID().uuidString
        defer { SecItemDelete(q as CFDictionary) }
        XCTAssertNil(q[kSecAttrAccessGroup as String])
        let token = try Credentials(response: TokenResponse(accessToken: "unit-private", refreshToken: "unit-private-refresh", idToken: nil, expiresIn: 3600))
        var add = q
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = try JSONEncoder().encode(token)
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        var read = q; read[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        let decoded = try JSONDecoder().decode(Credentials.self, from: XCTUnwrap(result as? Data))
        XCTAssertEqual(decoded.refreshToken, "unit-private-refresh")
    }
    func testSameSubjectDeduplicatesButDifferentWorkspaceDoesNot() async throws {
        guard try SharedStorage.accountIDs().isEmpty else { throw XCTSkip("Existing credentials") }
        defer { try? SharedStorage.clear() }
        func fixture(_ workspace: String, refresh: String) throws -> Credentials {
            let payload = try JSONSerialization.data(withJSONObject: ["sub": "unit-user", "https://api.openai.com/auth": ["chatgpt_account_id": workspace]]).base64EncodedString()
            return try Credentials(response: TokenResponse(accessToken: "unit.\(payload).unit", refreshToken: refresh, idToken: nil, expiresIn: 3600))
        }
        try await UsageService.shared.install(fixture("one", refresh: "unit-old"))
        try await UsageService.shared.install(fixture("one", refresh: "unit-new"))
        XCTAssertEqual(try SharedStorage.accountIDs().count, 1)
        XCTAssertEqual(try SharedStorage.credentials()?.refreshToken, "unit-new")
        try await UsageService.shared.install(fixture("two", refresh: "unit-two"))
        XCTAssertEqual(try SharedStorage.accountIDs().count, 2)
    }
    // MARK: - Display identity, masking switch and shared-snapshot privacy
    func testLabelPolicyMasksInSharedSnapshotUnlessOptedIn() {
        let identity = "alex@example.com"
        XCTAssertEqual(SharedStorage.snapshotLabel(email: identity, plan: "plus", showFull: false), "ale***@example.com · Plus")
        XCTAssertEqual(SharedStorage.snapshotLabel(email: identity, plan: "plus", showFull: true), "alex@example.com · Plus")
        XCTAssertEqual(SharedStorage.snapshotLabel(email: identity, plan: nil, showFull: false), "ale***@example.com")
        XCTAssertEqual(SharedStorage.snapshotLabel(email: nil, plan: nil, showFull: false), AccountLabel.unknownIdentity)
        XCTAssertEqual(SharedStorage.snapshotLabel(email: nil, plan: "pro", showFull: true), "未命名账号 · Pro")
    }
    func testMaskingSwitchDefaultsOffAndSharedSnapshotOmitsFullIdentity() throws {
        let identity = "alex@example.com"
        let account = "unit-label-policy"
        defer { try? SharedStorage.clearSnapshot(account: account) }
        // Default must be masked, even before any switch file has ever been written.
        XCTAssertFalse(SharedStorage.showFullAccountInWidget)
        XCTAssertEqual(SharedStorage.snapshotLabel(email: identity, plan: "plus"), "ale***@example.com · Plus")
        let masked = UsageSnapshot(usage: UsageResponse(planType: "plus", rateLimit: nil), updatedAt: Date(timeIntervalSince1970: 1),
                                   accountLabel: SharedStorage.snapshotLabel(email: identity, plan: "plus", showFull: false))
        let url = try SharedStorage.snapshotURL(account)
        try JSONEncoder().encode(masked).write(to: url, options: .atomic)
        let written = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(written.contains("ale***@example.com · Plus"))
        XCTAssertFalse(written.contains(identity))
        XCTAssertFalse(written.contains("alex"))
        // Opt-in path requires a real shared container; without one it must stay masked.
        do {
            try SharedStorage.setShowFullAccountInWidget(true)
            XCTAssertTrue(SharedStorage.showFullAccountInWidget)
            let full = UsageSnapshot(usage: UsageResponse(planType: "plus", rateLimit: nil), updatedAt: Date(timeIntervalSince1970: 1),
                                     accountLabel: SharedStorage.snapshotLabel(email: identity, plan: "plus"))
            try JSONEncoder().encode(full).write(to: url, options: .atomic)
            XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(identity))
        } catch {
            XCTAssertFalse(SharedStorage.showFullAccountInWidget)
        }
        try? SharedStorage.setShowFullAccountInWidget(false)
        XCTAssertFalse(SharedStorage.showFullAccountInWidget)
    }
    func testLegacySnapshotWithoutLabelStillDecodes() throws {
        let legacy = Data(#"{"usage":{"rate_limit":null},"updatedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: legacy)
        XCTAssertNil(decoded.accountLabel)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("\"updatedAt\""))
    }
    func testMaskingSwitchRoundTripsAndOnlyTheAppMayChangeIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("widget-identity-display.json")
        // Absent file (and no container at all) -> masked default.
        XCTAssertFalse(SharedStorage.showFullAccountInWidget(at: url))
        XCTAssertFalse(SharedStorage.showFullAccountInWidget(at: nil))
        try SharedStorage.setShowFullAccountInWidget(true, at: url, isWidget: false)
        XCTAssertTrue(SharedStorage.showFullAccountInWidget(at: url))
        // The extension must never be able to widen exposure.
        XCTAssertThrowsError(try SharedStorage.setShowFullAccountInWidget(true, at: url, isWidget: true))
        XCTAssertThrowsError(try SharedStorage.setShowFullAccountInWidget(true, at: nil, isWidget: false))
        // Turning it off deletes the file so the masked default applies again.
        try SharedStorage.setShowFullAccountInWidget(false, at: url, isWidget: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(SharedStorage.showFullAccountInWidget(at: url))
    }
    func testSharedContainerLockRejectsConcurrentWriter() throws {
        let lease = try CredentialLease()
        defer { withExtendedLifetime(lease) {} }
        XCTAssertThrowsError(try CredentialLease()) { error in
            guard case ServiceError.busy = error else { return XCTFail("Expected busy") }
        }
    }
    func testKeychainAndCacheRoundTripThenLogout() async throws {
        guard try SharedStorage.credentials() == nil else { throw XCTSkip("Never overwrite existing phone credentials") }
        let token = TokenResponse(accessToken: "unit-test-only", refreshToken: "unit-test-refresh", idToken: nil, expiresIn: 3600)
        try await UsageService.shared.install(Credentials(response: token))
        XCTAssertEqual(try SharedStorage.credentials()?.accessToken, "unit-test-only")
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rate_limit":{"primary_window":{"used_percent":25}}}"#.utf8))
        try SharedStorage.save(UsageSnapshot(usage: usage, updatedAt: Date()))
        XCTAssertEqual(SharedStorage.snapshot()?.usage.rateLimit?.primaryWindow?.remaining, 75)
        try await UsageService.shared.logout()
        XCTAssertNil(try SharedStorage.credentials())
        XCTAssertNil(SharedStorage.snapshot())
    }
    // MARK: - Legacy display-identity backfill (read-only: no network, no refresh)
    private func jwt(_ payload: [String: Any]) throws -> String {
        func part(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return try part(["alg": "none", "typ": "JWT"]) + "." + (try part(payload)) + ".signature"
    }
    private func recordQuery(_ account: String) -> [String: Any] {
        var q = SharedStorage.routing.query(); q[kSecAttrAccount as String] = account; return q
    }
    /// Simulates a build-5-era record: the keychain item holds tokens but has no `email` key
    /// (the display field did not exist when it was written).
    private func writeLegacyRecord(accessToken: String, account: String, storedEmail: String? = nil) throws {
        var object: [String: Any] = ["accessToken": accessToken, "refreshToken": "unit-legacy-refresh",
                                     "accountID": "unit-legacy-account", "expiresAt": 4_000_000_000]
        if let storedEmail { object["email"] = storedEmail }
        let q = recordQuery(account)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = try JSONSerialization.data(withJSONObject: object)
        let status = SecItemAdd(add as CFDictionary, nil)
        // A signing configuration whose keychain-access-groups entitlement omits the app's
        // own default group cannot host a private item; skip instead of a false failure.
        if status == errSecMissingEntitlement { throw XCTSkip("Keychain unavailable in this signing configuration (\(status))") }
        XCTAssertEqual(status, errSecSuccess)
    }
    private func storedRecord(_ account: String) throws -> [String: Any]? {
        var q = recordQuery(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func removeLegacyRecord(_ account: String) {
        SecItemDelete(recordQuery(account) as CFDictionary)
        try? SharedStorage.clearSnapshot(account: account)
    }
    func testLegacyRecordWithoutStoredIdentityRecoversEmailFromAccessTokenClaims() throws {
        let account = "unit-legacy-identity"
        defer { removeLegacyRecord(account) }
        let access = try jwt(["exp": 4_000_000_000, "https://api.openai.com/profile": ["email": "alex@example.com"]])
        try writeLegacyRecord(accessToken: access, account: account)
        // No transport and no refresh anywhere here: the identity comes from the stored access token.
        let recovered = try XCTUnwrap(try SharedStorage.credentials(account: account))
        XCTAssertEqual(recovered.email, "alex@example.com")
        let persisted = try XCTUnwrap(try storedRecord(account))
        // Persisted so it survives, and credentials are copied verbatim (no rotation, no refresh).
        XCTAssertEqual(persisted["email"] as? String, "alex@example.com")
        XCTAssertEqual(persisted["accessToken"] as? String, access)
        XCTAssertEqual(persisted["refreshToken"] as? String, "unit-legacy-refresh")
        XCTAssertEqual(try SharedStorage.credentials(account: account)?.refreshToken, "unit-legacy-refresh")
    }
    func testTopLevelEmailClaimAndOneOfTwoAccountsRecoverIndependently() throws {
        let withClaim = "unit-legacy-toplevel"
        let withoutClaim = "unit-legacy-sibling"
        defer { removeLegacyRecord(withClaim); removeLegacyRecord(withoutClaim) }
        try writeLegacyRecord(accessToken: try jwt(["exp": 4_000_000_000, "email": "toplevel@example.com"]), account: withClaim)
        try writeLegacyRecord(accessToken: "unit-not-a-jwt", account: withoutClaim)
        XCTAssertEqual(try SharedStorage.credentials(account: withClaim)?.email, "toplevel@example.com")
        // The sibling with no usable claim keeps the neutral placeholder, not the other account's name.
        XCTAssertNil(try SharedStorage.credentials(account: withoutClaim)?.email)
        XCTAssertEqual(SharedStorage.snapshotLabel(email: try SharedStorage.credentials(account: withoutClaim)?.email, plan: nil), AccountLabel.unknownIdentity)
    }
    func testRecoveredIdentityFeedsAppAndWidgetLabelPaths() throws {
        let account = "unit-legacy-label"
        defer { removeLegacyRecord(account) }
        try writeLegacyRecord(accessToken: try jwt(["exp": 4_000_000_000, "https://api.openai.com/profile": ["email": "alex@example.com"]]), account: account)
        // App label path: UsageModel.label(for:) reads accountEmail(id) and shows it unmasked.
        let appIdentity = try XCTUnwrap(SharedStorage.accountEmail(account))
        XCTAssertEqual(AccountLabel.text(identity: appIdentity, plan: AccountLabel.plan("plus"), masked: false), "alex@example.com · Plus")
        // Widget label path: the snapshot label built from the same credentials is masked by default.
        XCTAssertEqual(SharedStorage.snapshotLabel(email: appIdentity, plan: "plus"), "ale***@example.com · Plus")
    }
    func testExistingSnapshotLabelIsRefreshedWhenIdentityIsRecovered() throws {
        let account = "unit-legacy-snapshot"
        defer { removeLegacyRecord(account) }
        try writeLegacyRecord(accessToken: try jwt(["exp": 4_000_000_000, "https://api.openai.com/profile": ["email": "alex@example.com"]]), account: account)
        // An old snapshot already written with the placeholder label.
        let url = try SharedStorage.snapshotURL(account)
        let stale = UsageSnapshot(usage: UsageResponse(planType: "plus", rateLimit: nil), updatedAt: Date(timeIntervalSince1970: 1), accountLabel: AccountLabel.unknownIdentity)
        try JSONEncoder().encode(stale).write(to: url, options: .atomic)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(AccountLabel.unknownIdentity))
        // Loading the credential recovers and persists the identity, then re-labels the stored snapshot.
        _ = try SharedStorage.credentials(account: account)
        let written = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(written.contains("ale***@example.com · Plus"), written)
        XCTAssertFalse(written.contains(AccountLabel.unknownIdentity), written)
        XCTAssertFalse(written.contains("alex@example.com"), written)
        XCTAssertFalse(written.contains("alex"), written)
    }
    func testSnapshotStaysMaskedWithRecoveredIdentityUnderDefaultSettings() throws {
        let account = "unit-legacy-masking"
        defer { removeLegacyRecord(account) }
        try writeLegacyRecord(accessToken: try jwt(["exp": 4_000_000_000, "https://api.openai.com/profile": ["email": "alex@example.com"]]), account: account)
        XCTAssertFalse(SharedStorage.showFullAccountInWidget)
        let identity = try XCTUnwrap(SharedStorage.accountEmail(account))
        let snapshot = UsageSnapshot(usage: UsageResponse(planType: "plus", rateLimit: nil), updatedAt: Date(timeIntervalSince1970: 1),
                                     accountLabel: SharedStorage.snapshotLabel(email: identity, plan: "plus"))
        let url = try SharedStorage.snapshotURL(account)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let written = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(written.contains("ale***@example.com · Plus"))
        XCTAssertFalse(written.contains("alex@example.com"))
        XCTAssertFalse(written.contains("alex"))
    }
    func testPlaceholderWhenClaimsCarryNoIdentityOrTokenIsMalformed() throws {
        let account = "unit-legacy-placeholder"
        defer { removeLegacyRecord(account) }
        // A structurally valid JWT whose claims carry no identity at all.
        try writeLegacyRecord(accessToken: try jwt(["exp": 4_000_000_000]), account: account)
        let noClaim = try XCTUnwrap(try SharedStorage.credentials(account: account))
        XCTAssertNil(noClaim.email)
        XCTAssertEqual(SharedStorage.snapshotLabel(email: noClaim.email, plan: nil), AccountLabel.unknownIdentity)
        XCTAssertNil((try XCTUnwrap(try storedRecord(account)))["email"])
        // A malformed / non-JWT access token must degrade to the placeholder, never crash.
        try writeLegacyRecord(accessToken: "unit-not-a-jwt", account: account)
        let malformed = try XCTUnwrap(try SharedStorage.credentials(account: account))
        XCTAssertNil(malformed.email)
        XCTAssertEqual(SharedStorage.snapshotLabel(email: malformed.email, plan: "plus"), "未命名账号 · Plus")
        XCTAssertNil((try XCTUnwrap(try storedRecord(account)))["email"])
        // A blank stored identity is treated as missing; with no claim it still shows the placeholder.
        try writeLegacyRecord(accessToken: "unit-not-a-jwt", account: account, storedEmail: "   ")
        XCTAssertEqual(SharedStorage.snapshotLabel(email: try SharedStorage.credentials(account: account)?.email, plan: nil), AccountLabel.unknownIdentity)
        XCTAssertEqual((try XCTUnwrap(try storedRecord(account)))["email"] as? String, "   ")
    }
    func testStoredIdentityIsNeverReplacedByTheTokenClaim() throws {
        let account = "unit-legacy-keep"
        defer { removeLegacyRecord(account) }
        try writeLegacyRecord(accessToken: try jwt(["https://api.openai.com/profile": ["email": "token@example.com"]]), account: account, storedEmail: "stored@example.com")
        XCTAssertEqual(try SharedStorage.credentials(account: account)?.email, "stored@example.com")
        XCTAssertEqual((try XCTUnwrap(try storedRecord(account)))["email"] as? String, "stored@example.com")
    }
}
#endif
