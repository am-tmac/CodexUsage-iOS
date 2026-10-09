import Foundation
import Security
import Darwin
import CryptoKit
#if os(iOS)
import WidgetKit
#endif

public enum SharedStorage {
    public static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "group.com.personal.CodexUsage" }
    static var isWidget: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    // Resolve once per process: never switch lock/keychain domains during token rotation.
    private static let capabilities: (routing: StorageRouting, diagnostics: StorageDiagnostics) = {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let configured = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String
        let suffix = Bundle.main.object(forInfoDictionaryKey: "KeychainGroupIdentifier") as? String ?? "com.personal.CodexUsage.shared"
        let baseline = KeychainProbe.probe(group: nil)
        var probes: [String: OSStatus] = [:]
        let group = authorizedGroup(configured: configured, actualDefaultGroup: baseline.1, suffix: suffix) { candidate in
            let status = KeychainProbe.probe(group: candidate).0
            probes[candidate] = status
            return status == errSecSuccess
        }
        return (StorageRouting(sharedURL: shared, authorizedGroup: group, isWidget: isWidget),
                StorageDiagnostics(configuredAppGroup: groupID, configuredKeychainGroup: configured, containerAvailable: shared != nil, defaultProbeStatus: baseline.0, observedDefaultGroup: baseline.1, probes: probes, selectedGroup: group, isWidget: isWidget))
    }()
    // App keeps its original default queries; Widget pins the exact verified group.
    // The service/account namespace is unchanged. No credential migration or duplication.
    static var routing: StorageRouting {
        StorageRouting(sharedURL: capabilities.routing.sharedURL, authorizedGroup: isWidget ? permittedGroup : nil, isWidget: isWidget)
    }
    static var diagnostics: StorageDiagnostics { capabilities.diagnostics }
    private static var consentURL: URL? { capabilities.routing.sharedURL?.appendingPathComponent("widget-refresh-consent.json") }
    static var consent: WidgetRefreshConsent? {
        guard let url = consentURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetRefreshConsent.self, from: data)
    }
    static var permittedGroup: String? {
        guard let consent else { return nil }
        // Strict path: consent plus a live session whose non-secret challenge actually travelled
        // App → Widget → App, and the group the App writes credentials into is the consented one.
        if let session = handshake(),
           consent.permits(group: diagnostics.selectedGroup, handshakeID: session.id,
                           connected: (try? session.appConfirmed(read: session.read)) == true),
           diagnostics.observedDefaultGroup == consent.group {
            return consent.group
        }
        // Acknowledged override (`forced`): the user accepted that in-widget refresh may still fail
        // if this re-signing does not give both bundles the same keychain group. It still requires a
        // group this device could really probe — the capability test then happens live, in the
        // widget, and a failure keeps the cache and says so instead of inventing numbers.
        if consent.permitsForced(group: diagnostics.selectedGroup) { return consent.group }
        return nil
    }
    static func setWidgetRefreshConsent(_ enabled: Bool, forced: Bool = false) throws {
        guard !isWidget, let url = consentURL else { throw ServiceError.storage("共享容器不可用") }
        if enabled {
            let value: WidgetRefreshConsent
            if forced {
                guard let group = diagnostics.selectedGroup, diagnostics.observedDefaultGroup == group
                else { throw ServiceError.storage("本机钥匙串精确组探针未成功：组件无法确定该用哪个 access-group，独立刷新无法开启。请在下方诊断查看 OSStatus（-34018 表示缺少 entitlement）。") }
                value = WidgetRefreshConsent(group: group, handshakeID: handshake()?.id ?? "", forced: true)
            } else {
                guard let session = handshake(), diagnostics.observedDefaultGroup == session.group,
                      try session.appConfirmed(read: session.read) else { throw ServiceError.storage("请先完成当前同组 App / Widget 跨进程握手") }
                value = WidgetRefreshConsent(group: session.group, handshakeID: session.id, forced: false)
            }
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Revoke permission only; never delete credentials used by the App.
            try FileManager.default.removeItem(at: url)
        }
        try publishWidgetSelection()
    }
    /// The same conditions the setter enforces, exposed so the settings row can name the missing
    /// step and disable the switch instead of accepting a tap that then fails silently.
    static var canEnableWidgetRefreshConsent: Bool {
        guard !isWidget, let session = handshake(),
              diagnostics.observedDefaultGroup == session.group else { return false }
        return (try? session.appConfirmed(read: session.read)) == true
    }
    /// True when the switch may still be turned on without the cross-process round trip: the device
    /// has one real, probeable keychain group, so the extension can at least be pointed at the right
    /// credential. The handshake round trip is evidence, not a capability, and on a re-signed build
    /// it can be impossible to complete — gating the switch on it leaves the user with no path.
    static var canForceWidgetRefreshConsent: Bool {
        guard !isWidget, cacheSharingAvailable, let group = diagnostics.selectedGroup else { return false }
        return diagnostics.observedDefaultGroup == group
    }
    /// One sentence naming exactly what has to happen next on the device.
    static var widgetConsentBlockerText: String {
        if isWidget { return "仅 App 可开启组件独立刷新" }
        if !cacheSharingAvailable { return "共享容器不可用（App 私有模式）：组件连缓存都读不到，也无法申请独立刷新。请先确认重签时 App 与扩展都带有同一个 App Group。" }
        if diagnostics.selectedGroup == nil { return "本机钥匙串精确组探针未成功：组件无法用同一 access-group 读取凭据，独立刷新无法开启。请在下方诊断查看 OSStatus（-34018 表示缺少 entitlement）。" }
        guard let session = handshake() else { return "还没有 24 小时内的跨进程握手。先点「开始非敏感跨进程验证」，把组件放到桌面让它渲染一次，再回到 App 点「检查握手结果」。" }
        if diagnostics.observedDefaultGroup != session.group { return "实测默认组与握手组不一致，请重新握手。" }
        return (try? session.appConfirmed(read: session.read)) == true ? "" : "等待组件写回随机挑战（握手没走完）。可以直接开启：那会记录为「未完成跨进程验证」的强制授权，组件会真实尝试刷新，读不到凭据时会显示刷新失败并保留缓存。"
    }
    // Display-only identity policy. Stored in the shared container because BOTH the
    // App and the extension write snapshots and must mask identically. Default (no
    // file) is masked: the full identity never reaches the shared snapshot unless
    // the user explicitly opts in. Tokens are never involved either way.
    private static var identityDisplayURL: URL? { capabilities.routing.sharedURL?.appendingPathComponent("widget-identity-display.json") }
    static var showFullAccountInWidget: Bool { showFullAccountInWidget(at: identityDisplayURL) }
    /// `url` is injected so the file semantics stay testable without a shared container.
    static func showFullAccountInWidget(at url: URL?) -> Bool {
        guard let url, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WidgetIdentityDisplay.self, from: data) else { return false }
        return value.showFullAccountInWidget
    }
    static func setShowFullAccountInWidget(_ enabled: Bool) throws {
        try setShowFullAccountInWidget(enabled, at: identityDisplayURL, isWidget: isWidget)
    }
    static func setShowFullAccountInWidget(_ enabled: Bool, at url: URL?, isWidget: Bool) throws {
        // Only the App may change the policy; the extension must never widen exposure.
        guard !isWidget, let url else { throw ServiceError.storage("共享容器不可用") }
        if enabled {
            try JSONEncoder().encode(WidgetIdentityDisplay(showFullAccountInWidget: true)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Disabling removes the file so the default (masked) applies everywhere.
            try FileManager.default.removeItem(at: url)
        }
    }
    /// The single place the shared snapshot label is produced, used by App and Widget.
    /// `showFull` is injected so both branches stay testable without a shared container.
    static func snapshotLabel(email: String?, plan: String?, showFull: Bool) -> String {
        AccountLabel.text(identity: email, plan: AccountLabel.plan(plan), masked: !showFull)
    }
    static func snapshotLabel(email: String?, plan: String?) -> String {
        snapshotLabel(email: email, plan: plan, showFull: showFullAccountInWidget)
    }
    static func accountEmail(_ account: String) -> String? { (try? credentials(account: account))?.displayIdentity }
    /// Re-labels existing snapshots after the masking switch changes, so the widget
    /// reflects the new policy without waiting for the next refresh.
    static func relabelSnapshots() {
        guard !isWidget, let ids = try? accountIDs() else { return }
        for id in ids {
            guard let snapshot = snapshot(account: id) else { continue }
            let relabeled = UsageSnapshot(usage: snapshot.usage, updatedAt: snapshot.updatedAt,
                                          accountLabel: snapshotLabel(email: accountEmail(id), plan: snapshot.usage.planType))
            try? JSONEncoder().encode(relabeled).write(to: snapshotURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    /// Rewrites only the display label of a stored snapshot so the widget shows a
    /// just-recovered identity without waiting for the next refresh. Masked unless the
    /// user opted in; no credentials or tokens are written here.
    private static func relabelSnapshot(account: String, identity: String?) {
        guard !isWidget, let snapshot = snapshot(account: account), let url = try? snapshotURL(account) else { return }
        let label = snapshotLabel(email: identity, plan: snapshot.usage.planType)
        guard snapshot.accountLabel != label else { return }
        let relabeled = UsageSnapshot(usage: snapshot.usage, updatedAt: snapshot.updatedAt, accountLabel: label)
        try? JSONEncoder().encode(relabeled).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func selectedCredentialGroup(_ id: String) -> String? {
        guard let group = permittedGroup else { return nil }
        var q = StorageRouting(sharedURL: nil, authorizedGroup: nil, isWidget: false).query()
        q[kSecAttrAccount as String] = id
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]], rows.count == 1,
              rows[0][kSecAttrAccessGroup as String] as? String == group else { return nil }
        return group
    }
    private static var handshakeURL: URL? { capabilities.routing.sharedURL?.appendingPathComponent("nonsecret-handshake.json") }
    static func handshake() -> ProbeHandshake? {
        guard let url = handshakeURL, let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(ProbeHandshake.self, from: data),
              UUID(uuidString: session.id) != nil, session.group == diagnostics.selectedGroup,
              Date().timeIntervalSince(session.createdAt) >= 0,
              (Date().timeIntervalSince(session.createdAt) < 86400 || consent?.handshakeID == session.id) else { return nil }
        return session
    }
    static func startHandshake() throws {
        guard !isWidget, let url = handshakeURL, let group = diagnostics.selectedGroup else { throw ServiceError.storage("共享容器或精确组探针未成功") }
        try setWidgetRefreshConsent(false)
        handshake()?.remove()
        let session = ProbeHandshake(group: group)
        let challenge = Data((UUID().uuidString + UUID().uuidString).utf8)
        try session.write(session.appAccount, data: challenge)
        guard try session.read(session.appAccount) == challenge else { session.remove(); throw ServiceError.storage("App 非敏感握手读回失败") }
        do { try JSONEncoder().encode(session).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { session.remove(); throw error }
    }
    static var handshakeText: String {
        guard let session = handshake() else { return "尚无有效握手（24 小时有效）；点击开始验证，然后查看组件并返回检查。" }
        do {
            let confirmed = try session.appConfirmed(read: session.read)
            return confirmed ? "跨进程握手成功：App 读到了 Widget 写回的同一随机挑战。可在知悉风险后开启独立刷新；不会迁移令牌。" : "等待 Widget 读取 App 的随机挑战并写回；两端各自探针成功不算握手成功。"
        } catch { return error.localizedDescription }
    }
    static func respondToHandshake() -> String {
        guard isWidget, let session = handshake() else { return "没有可用的同组握手请求" }
        do { return try session.widgetRespond(read: session.read, write: { try session.write($0, data: $1) }) ? "Widget 已读取 App 挑战并写回；等待 App 检查" : "Widget 未读到 App 挑战（不可据此启用共享）" }
        catch { return error.localizedDescription }
    }
    static func recordWidgetDiagnostics() {
        guard isWidget, let url = try? container().appendingPathComponent("widget-diagnostics.json") else { return }
        var report = diagnostics
        report.handshakeStatus = respondToHandshake()
        try? JSONEncoder().encode(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static var widgetDiagnosticText: String {
        guard let url = try? container().appendingPathComponent("widget-diagnostics.json"), let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(StorageDiagnostics.self, from: data) else { return "尚无扩展诊断；扩展未运行或不能访问同一 App Group。App 的成功不证明扩展成功。" }
        return report.text
    }
    static var sharingAvailable: Bool { permittedGroup != nil }
    static var sharingMessage: String { "共享未授权 · 打开 App 配置签名" }
    /// Test seam: `swift test` runs without an App Group, so tests point the cache at a temp dir.
    nonisolated(unsafe) static var containerOverride: URL?
    static func container() throws -> URL {
        if let containerOverride { return try container(sharedURL: containerOverride, localURL: containerOverride) }
        return try routing.cacheContainer(localURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexUsage", isDirectory: true))
    }
    static func container(sharedURL: URL?, localURL: URL) throws -> URL {
        let url = sharedURL ?? localURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func authorizedGroup(configured: String?, actualDefaultGroup: String?, suffix: String, authorize: (String) -> Bool) -> String? {
        if let configured, !configured.isEmpty, !configured.contains("$("), !configured.contains("*"), authorize(configured) { return configured }
        // Runtime attributes are opaque identifiers, including a literal '*'. Never
        // expand a wildcard or infer a concrete child group from a team prefix.
        if let candidate = actualDefaultGroup, !candidate.isEmpty,
           !candidate.contains("$("), authorize(candidate) { return candidate }
        return nil
    }
    static func query(account: String = "phone-owned") -> [String: Any] {
        var q = routing.query(); q[kSecAttrAccount as String] = account; return q
    }
    static func accountIDs() throws -> [String] {
        try routing.requireAccess()
        var q = routing.query(); q.removeValue(forKey: kSecAttrAccount as String)
        q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ServiceError.storage("Keychain \(status)") }
        return (result as? [[String: Any]] ?? []).sorted {
            ($0[kSecAttrCreationDate as String] as? Date ?? .distantPast) < ($1[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    static func identity(_ credentials: Credentials) -> String {
        // Subject distinguishes two users in the same workspace. Claims are routing
        // hints only, not verified identity. No subject: keep separate rather than merge.
        guard let subject = Credentials.claims(credentials.accessToken)?["sub"] as? String else { return UUID().uuidString }
        return SHA256.hash(data: Data((subject + "|" + (credentials.accountID ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func widgetState() -> WidgetCacheState? {
        guard let url = try? container().appendingPathComponent("widget-state.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetCacheState.self, from: data)
    }
    static var cacheSharingAvailable: Bool { routing.sharedURL != nil }
    static var widgetCanRefresh: Bool {
        let route = StorageRouting(sharedURL: capabilities.routing.sharedURL, authorizedGroup: permittedGroup, isWidget: true)
        return widgetState()?.allowsRefresh(using: route) == true
    }
    static func selectedAccount() -> String? {
        // The extension must not enumerate private Keychain to locate a safe cache.
        if isWidget { return widgetState()?.account }
        guard let ids = try? accountIDs() else { return nil }
        if let selected = widgetState()?.account, ids.contains(selected) { return selected }
        if let url = try? container().appendingPathComponent("widget-account.txt"), let selected = try? String(contentsOf: url, encoding: .utf8), ids.contains(selected) { return selected }
        return ids.first
    }
    static func publishWidgetSelection() throws {
        guard !isWidget else { return }
        try DashboardStore.publish()
        let url = try container().appendingPathComponent("widget-state.json")
        guard let id = selectedAccount() else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try writeWidgetState(id, to: url)
    }
    private static func writeWidgetState(_ id: String, to url: URL) throws {
        let state = WidgetCacheState(account: id, credentialGroup: selectedCredentialGroup(id))
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func selectWidgetAccount(_ id: String) throws {
        guard try accountIDs().contains(id) else { throw ServiceError.loginRequired }
        try writeWidgetState(id, to: container().appendingPathComponent("widget-state.json"))
    }
    static func snapshotURL(_ account: String?) throws -> URL {
        let id = account ?? selectedAccount() ?? "phone-owned"
        let name = id == "phone-owned" ? "usage.json" : "usage-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        return try container().appendingPathComponent(name)
    }
    static func clearSnapshot(account: String?) throws {
        let url = try snapshotURL(account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public static func credentials(account: String? = nil) throws -> Credentials? {
        try credentials(account: account, route: routing)
    }
    static func credentials(account: String?, route: StorageRouting) throws -> Credentials? {
        try credentials(account: account, route: route, recoveringDisplayIdentity: true)
    }
    /// `recoveringDisplayIdentity` is false only for the guarded re-read inside the
    /// backfill write, so recovery can never recurse.
    private static func credentials(account: String?, route: StorageRouting, recoveringDisplayIdentity: Bool) throws -> Credentials? {
        try route.requireAccess()
        let id = account ?? selectedAccount() ?? "phone-owned"
        var q = route.query(); q[kSecAttrAccount as String] = id; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ServiceError.storage("Keychain \(status)") }
        let stored = try JSONDecoder().decode(Credentials.self, from: data)
        guard recoveringDisplayIdentity else { return stored }
        return recoverDisplayIdentity(stored, account: id, route: route)
    }
    /// Read-only fallback for records written before the display identity existed:
    /// derive it at load time from the claims of the access token stored alongside it
    /// (same rules as login) and persist it so it survives. Display-only — never
    /// authentication, routing or verification; no network call and no token refresh.
    /// A record whose token carries no usable claim is returned untouched and keeps
    /// the neutral placeholder. Existing snapshots are re-labelled (masked by default)
    /// so the widget stops showing the placeholder without waiting for a refresh.
    private static func recoverDisplayIdentity(_ stored: Credentials, account: String, route: StorageRouting) -> Credentials {
        guard let recovered = stored.recoveredDisplayIdentity() else { return stored }
        // Re-read immediately before writing and only persist what is still current, so
        // a concurrent token rotation can never be rolled back by this label recovery.
        guard let fresh = try? credentials(account: account, route: route, recoveringDisplayIdentity: false),
              fresh.accessToken == stored.accessToken, fresh.refreshToken == stored.refreshToken else { return stored }
        let updated = Credentials(accessToken: fresh.accessToken, refreshToken: fresh.refreshToken,
                                  accountID: fresh.accountID, email: recovered, expiresAt: fresh.expiresAt)
        guard (try? save(updated, account: account, route: route)) != nil else { return stored }
        relabelSnapshot(account: account, identity: recovered)
        return updated
    }
    static func save(_ credentials: Credentials, account: String = "phone-owned", route: StorageRouting = routing) throws {
        try route.requireAccess()
        var query = route.query(); query[kSecAttrAccount as String] = account
        let data = try JSONEncoder().encode(credentials)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServiceError.storage("Keychain \(status)") }
    }
    public static func snapshot(account: String? = nil) -> UsageSnapshot? {
        guard let url = try? snapshotURL(account), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
    static func save(_ snapshot: UsageSnapshot, account: String? = nil) throws {
        try JSONEncoder().encode(snapshot).write(to: snapshotURL(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try publishWidgetSelection()
    }
    static func clear(account: String? = nil) throws {
        try routing.requireAccess()
        let ids = try account.map { [$0] } ?? accountIDs()
        for id in ids {
            let status = SecItemDelete(query(account: id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.storage("Keychain \(status)") }
            try clearSnapshot(account: id)
        }
        try publishWidgetSelection()
    }
}

// Diagnostics intentionally contain only public identifiers and non-secret probe results.
// No private SecTask API, credential queries, profile/device identifiers, or tokens.
struct StorageDiagnostics: Codable {
    let configuredAppGroup: String
    let configuredKeychainGroup: String?
    let containerAvailable: Bool
    let defaultProbeStatus: OSStatus
    let observedDefaultGroup: String?
    let probes: [String: OSStatus]
    let selectedGroup: String?
    let isWidget: Bool
    var observedAt = Date()
    var handshakeStatus: String? = nil
    var text: String {
        let mode = !containerAvailable ? "共享容器不可用" : "缓存共享可用 · 独立联网状态以同意开关及当前握手为准"
        return """
        \(isWidget ? "Widget" : "App") · \(observedAt.formatted(date: .abbreviated, time: .standard))
        App Group 配置：\(configuredAppGroup)
        容器获取：\(containerAvailable ? "成功" : "失败 (nil)")
        Keychain 配置：\(configuredKeychainGroup ?? "未配置")
        默认非敏感探针 OSStatus：\(defaultProbeStatus)
        实测默认 access-group：\(observedDefaultGroup ?? "不可读取")
        \(probes.sorted { $0.key < $1.key }.map { "共享探针 \($0.key)：OSStatus \($0.value)" }.joined(separator: "\n"))
        选中 Keychain 组：\(selectedGroup ?? "无；不向私有查询传 access-group")
        存储模式：\(mode)
        完整有效签名 entitlement 列表：此 iOS 公共 API 路径不可读；配置不等于授权。上述 group 来自本 App 创建的非敏感探针属性，并非 profile 推测。
        跨进程握手：\(handshakeStatus ?? "请使用下方非敏感验证")
        -34018：缺少 entitlement；-25308：设备锁定/交互不可用。实测默认组按原样探测，包括字面 *，绝不推导子组。单独探针或握手不会自动授权；还需明确同意开关。
        安全边界：购买证书的默认组可能被其他同组 App 访问。省略 access-group 或使用 private service 并不提供 App 私有的安全隔离；已有令牌也可能位于这个组。服务名不是访问控制。
        """
    }
}

// Only opaque account selection and capability metadata; never credentials.
struct WidgetRefreshConsent: Codable {
    let group: String
    let handshakeID: String
    /// True when the user accepted the shared-group risk without the App ⇄ Widget round trip
    /// completing. Optional so consent files written before the override existed still decode.
    var forced: Bool? = nil
    func permits(group: String?, handshakeID: String?, connected: Bool) -> Bool {
        connected && group == self.group && handshakeID == self.handshakeID
    }
    /// The acknowledged override: no round trip required, but the group must still be one this
    /// device could actually probe, so the extension is pointed at a real credential group.
    func permitsForced(group: String?) -> Bool {
        (forced ?? false) && group != nil && group == self.group
    }
}
struct WidgetCacheState: Codable {
    let account: String
    let credentialGroup: String?
    func allowsRefresh(using routing: StorageRouting) -> Bool {
        routing.isShared && credentialGroup != nil && credentialGroup == routing.authorizedGroup
    }
}
// Non-secret display policy; no credentials or tokens.
struct WidgetIdentityDisplay: Codable {
    let showFullAccountInWidget: Bool
}

struct StorageRouting {
    let sharedURL: URL?
    let authorizedGroup: String?
    let isWidget: Bool
    var isShared: Bool { sharedURL != nil && authorizedGroup != nil }
    func cacheContainer(localURL: URL) throws -> URL {
        if isWidget && sharedURL == nil { throw ServiceError.storage(SharedStorage.sharingMessage) }
        return try SharedStorage.container(sharedURL: sharedURL, localURL: localURL)
    }
    func requireAccess() throws {
        if isWidget && !isShared { throw ServiceError.storage(SharedStorage.sharingMessage) }
    }
    func query() -> [String: Any] {
        // Service is a namespace, NOT access control. Preserve build3 items exactly.
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CodexUsage.OAuth.private",
            kSecAttrAccount as String: "phone-owned"]
        if isShared { q[kSecAttrAccessGroup as String] = authorizedGroup }
        return q
    }
}
// The challenge and response stay in Keychain. The shared file contains only a
// random session identifier and exact observed group, never the challenge or tokens.
struct ProbeHandshake: Codable {
    let group: String
    var id = UUID().uuidString
    var createdAt = Date()
    var appAccount: String { "app-" + id }
    var widgetAccount: String { "widget-" + id }
    func widgetRespond(read: (String) throws -> Data?, write: (String, Data) throws -> Void) throws -> Bool {
        guard let challenge = try read(appAccount), !challenge.isEmpty else { return false }
        try write(widgetAccount, challenge)
        return try read(widgetAccount) == challenge
    }
    func appConfirmed(read: (String) throws -> Data?) throws -> Bool {
        guard let challenge = try read(appAccount), !challenge.isEmpty else { return false }
        return try read(widgetAccount) == challenge
    }
    func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.CodexUsage.nonsecret-handshake.v1",
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }
    func read(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ServiceError.storage("非敏感握手读取 OSStatus \(status)") }
        return result as? Data
    }
    func write(_ account: String, data: Data) throws {
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(account).merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ServiceError.storage("非敏感握手写入 OSStatus \(status)") }
    }
    func remove() {
        for account in [appAccount, widgetAccount] { SecItemDelete(query(account) as CFDictionary) }
    }
}
private enum KeychainProbe {
    static func probe(group: String?) -> (OSStatus, String?) {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CodexUsage.capability-probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("non-secret-capability-probe".utf8)]
        if let group { q[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        var add = q; add[kSecReturnAttributes as String] = true
        let status = SecItemAdd(add as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        defer { SecItemDelete(q as CFDictionary) }
        let observed = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        var read = q; read.removeValue(forKey: kSecValueData as String)
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &value)
        guard readStatus == errSecSuccess else { return (readStatus, observed) }
        return ((value as? Data) == (q[kSecValueData as String] as? Data) ? errSecSuccess : errSecDecode, observed)
    }
    static func defaultAccessGroup() -> String? { probe(group: nil).1 }
    static func authorized(_ group: String) -> Bool { probe(group: group).0 == errSecSuccess }
}

// Kernel lock serializes the entire read-refresh-persist cycle across App and Widget.
// Nonblocking: an extension never waits indefinitely for a suspended foreground App.
final class CredentialLease {
    private let fd: Int32
    init(account: String? = nil) throws {
        let name = account.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "refresh"
        fd = open(try SharedStorage.container().appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ServiceError.storage("锁文件不可用") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ServiceError.busy }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
struct WidgetRefreshAttempt: Codable {
    var nextAllowed = Date.distantPast
    var failures = 0
    // Optional fields decode build4 attempt files without discarding their backoff.
    var startedAt: Date?
    var completedAt: Date?
    /// Optional so older records retain their original backoff when decoded.
    /// Claude's extension can read access tokens but only the App may renew them.
    var needsAppRefresh: Bool? = nil
    var requiresAppRefresh: Bool { needsAppRefresh == true }
    static let progressLifetime: TimeInterval = 120
    var failed: Bool { failures > 0 }
    func isRefreshing(at now: Date) -> Bool {
        guard let startedAt else { return false }
        return now >= startedAt && now.timeIntervalSince(startedAt) < Self.progressLifetime
    }
    func allows(_ now: Date) -> Bool { now >= nextAllowed }
    mutating func begin(_ now: Date) {
        startedAt = now
        nextAllowed = now.addingTimeInterval(60)
    }
    /// After a success the next tap may fetch again in 20 s (was 60 s, which made the widget
    /// button look dead for a minute). Failures still back off from 5 minutes.
    static let successCooldown: TimeInterval = 20
    mutating func succeed(_ now: Date) {
        startedAt = nil
        completedAt = now
        failures = 0
        needsAppRefresh = false
        nextAllowed = now.addingTimeInterval(Self.successCooldown)
    }
    mutating func requireAppRefresh(_ now: Date) {
        let previousBackoff = nextAllowed
        fail(now)
        needsAppRefresh = true
        nextAllowed = max(previousBackoff, nextAllowed)
    }
    /// The App persisted a freshly rotated token. The widget can use it again even when the
    /// usage request that followed failed, so only the renewal marker is cleared; failure
    /// counting and backoff stay with `fail`.
    mutating func authorizationRenewed() { needsAppRefresh = false }
    // Only call while owning the account lease: no live writer can be clobbered.
    mutating func recoverInterrupted(_ now: Date) {
        guard startedAt != nil else { return }
        startedAt = nil
        completedAt = now
        failures = max(1, failures)
        // Preserve original throttle/backoff after an interrupted extension.
    }
    mutating func fail(_ now: Date) {
        startedAt = nil
        completedAt = now
        failures = min(failures + 1, 5)
        nextAllowed = now.addingTimeInterval(min(3600, 300 * pow(2, Double(failures - 1))))
    }
    static func url(_ account: String) throws -> URL { try SharedStorage.snapshotURL(account).appendingPathExtension("attempt") }
    static func load(_ account: String) -> Self {
        guard let url = try? url(account), let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ account: String) throws {
        try JSONEncoder().encode(self).write(to: Self.url(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
/// A refresh grant usually invalidates the previous refresh token the moment it answers, so a
/// rotated token that is not written down is a lost login. Retry the write once (a keychain that
/// is briefly locked often recovers), then fail loudly instead of carrying on with a token that
/// exists only in memory.
enum RotationPersistence {
    static func save(_ write: () throws -> Void) throws {
        do { try write() } catch { try write() }
    }
}

public actor UsageService {
    public static let shared = UsageService()
    private let api: AuthAPI
    init(api: AuthAPI = AuthAPI()) { self.api = api }
    public func install(_ credentials: Credentials) throws {
        try Task.checkCancellation()
        let lease = try CredentialLease(); defer { withExtendedLifetime(lease) {} }
        let identity = SharedStorage.identity(credentials)
        let ids = try SharedStorage.accountIDs()
        // Retain the legacy single-account key when its subject/workspace matches.
        let id = try ids.first { existing in
            guard let old = try SharedStorage.credentials(account: existing) else { return false }
            return SharedStorage.identity(old) == identity
        } ?? (ids.isEmpty ? "phone-owned" : identity)
        let accountLease = try CredentialLease(account: id); defer { withExtendedLifetime(accountLease) {} }
        try SharedStorage.save(credentials, account: id)
        try SharedStorage.clearSnapshot(account: id)
        try SharedStorage.publishWidgetSelection()
    }
    public func logout(account: String? = nil) throws {
        let lease = try CredentialLease(account: account); defer { withExtendedLifetime(lease) {} }
        try SharedStorage.clear(account: account)
    }
    public func refresh(account: String? = nil) async throws -> UsageSnapshot {
        try await refresh(account: account, widget: SharedStorage.isWidget, permission: {
            if let account { return DashboardStore.canRefresh(account, provider: "codex") }
            return SharedStorage.widgetCanRefresh
        })
    }
    // Injectable permission seam exercises revoke/cancellation without phone secrets.
    func refresh(account: String?, widget: Bool, permission: () -> Bool) async throws -> UsageSnapshot {
        func checkPermission() throws {
            try Task.checkCancellation()
            if widget && !permission() { throw ServiceError.storage("仅缓存 · 打开 App 刷新") }
        }
        try checkPermission()
        guard let id = account ?? SharedStorage.selectedAccount() else { throw ServiceError.loginRequired }
        let lease = try CredentialLease(account: id); defer { withExtendedLifetime(lease) {} }
        let route = SharedStorage.routing // Freeze for rotation persistence, even after revoke.
        var attempt = WidgetRefreshAttempt.load(id)
        if widget {
            // Holding the exclusive account lease proves no live writer exists, so any
            // persisted start marker belongs to an extension killed mid-fetch: clear it
            // and keep the original throttle/backoff before deciding whether to fetch.
            let abandoned = attempt.startedAt != nil
            attempt.recoverInterrupted(Date())
            if abandoned { try? attempt.save(id) }
            guard attempt.allows(Date()) else {
                if let cache = SharedStorage.snapshot(account: id) { return cache }
                throw ServiceError.busy
            }
            attempt.begin(Date()); try attempt.save(id)
            // Persisted progress is served by the provider without a second request.
            #if os(iOS)
            WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
            #endif
        }
        do {
            try checkPermission()
            guard var credentials = try SharedStorage.credentials(account: id, route: route) else { throw ServiceError.loginRequired }
            if credentials.expiresAt.timeIntervalSinceNow < 120 {
                try checkPermission()
                credentials = try await api.refresh(credentials)
                // Save a completed rotation before observing cancellation/revocation.
                let rotated = credentials
                try RotationPersistence.save { try SharedStorage.save(rotated, account: id, route: route) }
            }
            let usage: UsageResponse
            do { try checkPermission(); usage = try await api.usage(credentials) }
            catch ServiceError.http(401) {
                try checkPermission()
                credentials = try await api.refresh(credentials)
                let rotated = credentials
                try RotationPersistence.save { try SharedStorage.save(rotated, account: id, route: route) }
                try checkPermission()
                usage = try await api.usage(credentials)
            }
            try checkPermission()
            let result = UsageSnapshot(usage: usage, updatedAt: Date(),
                                       accountLabel: SharedStorage.snapshotLabel(email: credentials.displayIdentity, plan: usage.planType))
            try SharedStorage.save(result, account: id)
            if widget { attempt.succeed(Date()); try attempt.save(id) }
            return result
        } catch {
            if widget { attempt.fail(Date()); try? attempt.save(id) }
            throw error // Provider/intent retain the last successful cache.
        }
    }
}


