import Foundation
import Security

// Nonsecret catalog: opaque local identifiers, provider and ordinal. No key or email.
struct DashboardAccount: Codable, Equatable, Identifiable {
    let id: String
    let provider: String
    let ordinal: Int
    let credentialGroup: String?
    var title: String {
        let name: String
        switch provider {
        case "deepseek": name = "DeepSeek"
        case "antigravity": name = "Antigravity"
        default: name = "Codex"
        }
        return "\(name) · 账号 \(ordinal)"
    }
}
enum DashboardStore {
    static func catalogURL() throws -> URL { try SharedStorage.container().appendingPathComponent("dashboard-accounts.json") }
    static func accounts() -> [DashboardAccount] {
        guard let url = try? catalogURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DashboardAccount].self, from: data)) ?? []
    }
    static func publish() throws {
        guard !SharedStorage.isWidget else { return }
        var rows = try SharedStorage.accountIDs().enumerated().map { index, id in
            DashboardAccount(id: id, provider: "codex", ordinal: index + 1, credentialGroup: SharedStorage.selectedCredentialGroup(id))
        }
        rows += try DeepSeekStore.ids().enumerated().map { index, id in
            DashboardAccount(id: id, provider: "deepseek", ordinal: index + 1, credentialGroup: DeepSeekStore.credentialGroup(id))
        }
        // Antigravity publishes one row so the widget picker can point a slot at it. Its credential
        // group is the group the token was written under.
        if AntigravityStore.installed() {
            rows.append(DashboardAccount(id: AntigravityStore.account, provider: "antigravity", ordinal: 1,
                                         credentialGroup: SharedStorage.permittedGroup))
        }
        try JSONEncoder().encode(rows).write(to: catalogURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Provider-agnostic variant used by the single widget refresh control, which must decide
    /// "may this slot refresh at all" before it consults each provider's own rules.
    static func canRefreshAnyProvider(_ id: String) -> Bool {
        guard SharedStorage.cacheSharingAvailable, let group = SharedStorage.permittedGroup,
              let row = accounts().first(where: { $0.id == id }) else { return false }
        return row.credentialGroup == group
    }
    static func canRefresh(_ id: String, provider: String) -> Bool {
        guard SharedStorage.cacheSharingAvailable, let group = SharedStorage.permittedGroup,
              let row = accounts().first(where: { $0.id == id && $0.provider == provider }) else { return false }
        return row.credentialGroup == group
    }
}
enum DeepSeekStore {
    static let service = "CodexUsage.DeepSeek.api-key.v1"
    static func query(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { q[kSecAttrAccount as String] = id }
        if SharedStorage.isWidget, let group = SharedStorage.permittedGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }
    static func ids() throws -> [String] {
        guard !SharedStorage.isWidget else { return DashboardStore.accounts().filter { $0.provider == "deepseek" }.map(\.id) }
        var q = query(); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw DeepSeekError.storage }
        return (result as? [[String: Any]] ?? []).sorted {
            ($0[kSecAttrCreationDate as String] as? Date ?? .distantPast) < ($1[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    static func credentialGroup(_ id: String) -> String? {
        guard let group = SharedStorage.permittedGroup else { return nil }
        var q = query(id); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]], rows.count == 1,
              rows[0][kSecAttrAccessGroup as String] as? String == group else { return nil }
        return group
    }
    static func saveKey(_ key: String, id: String) throws {
        guard !SharedStorage.isWidget else { throw DeepSeekError.storage }
        let value = try DeepSeekAPI.validatedKey(key)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let q = query(id)
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw DeepSeekError.storage }
    }
    static func key(_ id: String) throws -> String? {
        if SharedStorage.isWidget && !DashboardStore.canRefresh(id, provider: "deepseek") { throw DeepSeekError.storage }
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw DeepSeekError.storage }
        return value
    }
    static func snapshotURL(_ id: String) throws -> URL { try SharedStorage.snapshotURL("deepseek:" + id).appendingPathExtension("balance") }
    static func snapshot(_ id: String) -> DeepSeekSnapshot? {
        guard let url = try? snapshotURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeepSeekSnapshot.self, from: data)
    }
    static func save(_ value: DeepSeekSnapshot, id: String) throws {
        try JSONEncoder().encode(value).write(to: snapshotURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove(_ id: String) throws {
        guard !SharedStorage.isWidget else { throw DeepSeekError.storage }
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeepSeekError.storage }
        for url in [try snapshotURL(id), try WidgetRefreshAttempt.url(id)] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
actor DeepSeekService {
    static let shared = DeepSeekService()
    let api: DeepSeekAPI
    init(api: DeepSeekAPI = DeepSeekAPI()) { self.api = api }
    func install(key: String, replacing id: String? = nil) throws -> String {
        let id = id ?? "deepseek-" + UUID().uuidString
        let lease = try CredentialLease(account: id); defer { withExtendedLifetime(lease) {} }
        try DeepSeekStore.saveKey(key, id: id)
        let url = try DeepSeekStore.snapshotURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try WidgetRefreshAttempt().save(id)
        try DashboardStore.publish()
        return id
    }
    func remove(_ id: String) throws {
        let lease = try CredentialLease(account: id); defer { withExtendedLifetime(lease) {} }
        try DeepSeekStore.remove(id); try DashboardStore.publish()
    }
    func refresh(id: String, widget: Bool = SharedStorage.isWidget, permission: (() -> Bool)? = nil) async throws -> DeepSeekSnapshot {
        func check() throws {
            try Task.checkCancellation()
            if widget && !(permission?() ?? DashboardStore.canRefresh(id, provider: "deepseek")) { throw DeepSeekError.storage }
        }
        try check()
        let lease = try CredentialLease(account: id); defer { withExtendedLifetime(lease) {} }
        var attempt = WidgetRefreshAttempt.load(id)
        attempt.recoverInterrupted(Date())
        if widget && !attempt.allows(Date()) {
            try attempt.save(id)
            if let cache = DeepSeekStore.snapshot(id) { return cache }
            throw ServiceError.busy
        }
        attempt.begin(Date()); try attempt.save(id)
        do {
            try check()
            guard let key = try DeepSeekStore.key(id) else { throw DeepSeekError.unauthorized }
            let balance = try await api.balance(key: key)
            try check()
            let value = DeepSeekSnapshot(balance: balance, updatedAt: Date())
            try DeepSeekStore.save(value, id: id)
            attempt.succeed(Date()); try attempt.save(id)
            return value
        } catch {
            attempt.fail(Date()); try? attempt.save(id)
            if error is CancellationError { throw CancellationError() }
            throw (error as? DeepSeekError) ?? DeepSeekError.storage
        }
    }
}
