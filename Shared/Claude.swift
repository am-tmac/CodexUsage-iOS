import Foundation
import Security
import CryptoKit

// Claude.ai subscription quota ("5 小时 / 每周" windows) read through Anthropic's own OAuth
// endpoints and the account-usage endpoint Claude Code itself calls.
//
// Anthropic does NOT authorise third-party apps to offer Claude.ai login or to collect, store or
// intermediate Claude.ai session tokens. This provider signs in with the Claude Code OAuth client
// (`9d1c250a-…`) — the public client id that ships inside every Claude Code / CLIProxyAPI install
// and only ever mints tokens for the user's own account. It is a compatibility choice, not an
// approval: the client, the scopes and the usage endpoint can change or be blocked at any time.
// The App requests the user's own consent in its panel and never presents this as compliant.
//
// What is stored: the OAuth **refresh token** only. The short-lived access token is exchanged on
// demand and never persisted, never written to a snapshot, never logged. No password is ever typed
// into the App.

struct ClaudeWindow: Codable, Equatable {
    /// Remaining share of the window (100 − the API's used percent). Nil when the API omits it.
    let remaining: Double?
    let reset: Date?
}
struct ClaudeSnapshot: Codable, Equatable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?
    let updatedAt: Date
    /// Same 30-minute freshness rule the other providers use; only ever used to label the cache.
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > 1800 || now < updatedAt }
}

enum ClaudeFailure: LocalizedError {
    case loginRequired, unauthorized, busy, unavailable, network, malformed, storage, listenerBusy
    var errorDescription: String? {
        switch self {
        case .loginRequired: return "尚未用 Claude 账号登录，请先在设置里登录"
        case .unauthorized: return "Claude 授权已失效或未获授权，请重新登录（不会询问密码）"
        case .busy: return "Claude 请求过于频繁，请稍后重试"
        case .unavailable: return "Claude 用量接口暂不可用；保留缓存，不推算额度"
        case .network: return "Claude 网络连接失败；保留缓存"
        case .malformed: return "Claude 用量格式已变化；保留缓存，不推算额度"
        case .storage: return "Claude 本机钥匙串或共享缓存不可用，请检查签名与权限"
        case .listenerBusy: return "本机回调端口 54545 被占用，登录无法开始；请关闭占用它的 App 后重试，或改用授权码方式"
        }
    }
}

/// The public OAuth client values and endpoints of the Claude Code sign-in. Verified against the
/// user's own working CLIProxyAPI (`GET /v0/management/anthropic-auth-url` returned exactly this
/// authorize URL, redirect URI and scope list) and against Anthropic's own endpoints
/// (`GET /api/oauth/profile` answers 401 "provide an OAuth token as a Bearer token"; a sibling path
/// answers 404, so the OAuth route is real).
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    /// The account usage window Claude Code's own `/usage` renders.
    static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    /// Required by the OAuth usage route; without a valid bearer the route answers 401 regardless.
    static let betaHeader = "oauth-2025-04-20"
    static let scopes = ["user:profile", "user:inference", "user:sessions:claude_code",
                         "user:mcp_servers", "user:file_upload"]
    /// The client registers exactly this loopback redirect, so the port is fixed — a random port
    /// would no longer match `redirect_uri`. 127.0.0.1 is bound; `localhost` also resolves there.
    static let callbackPort: UInt16 = 54545
    static let redirectURI = "http://localhost:54545/callback"
    static let callbackPath = "/callback"
    /// Fallback the Claude CLI offers: approve in a real browser and paste the one-time code.
    static let consoleRedirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let consoleCallbackPath = "/oauth/code/callback"

    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
    static func codeChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
    static func authorizeURL(state: String, challenge: String, redirectURI: String = ClaudeOAuth.redirectURI) -> URL {
        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                                 URLQueryItem(name: "response_type", value: "code"),
                                 URLQueryItem(name: "redirect_uri", value: redirectURI),
                                 URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                                 URLQueryItem(name: "code_challenge", value: challenge),
                                 URLQueryItem(name: "code_challenge_method", value: "S256"),
                                 URLQueryItem(name: "state", value: state),
                                 // The CLI asks for the copyable-code form so both flows work.
                                 URLQueryItem(name: "code", value: "true")]
        return components.url!
    }

    /// Parse only the registered callback path and require the one-time state before accepting
    /// either a code or an error; a denied consent can never be exchanged.
    enum Callback: Equatable { case code(String, String), failure(String) }
    static func parseCallback(_ requestLine: String, expectedState: String) -> Callback? {
        guard let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost" + target),
              components.path == callbackPath else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return nil }
        if let error = value("error"), !error.isEmpty { return .failure(error) }
        if let code = value("code"), !code.isEmpty { return .code(code, expectedState) }
        return nil
    }
    /// The console flow shows `code#state` for the user to copy. Only the one-time code and the
    /// state that came with it are accepted; anything else is rejected rather than guessed.
    static func parsePastedCode(_ text: String) -> Callback? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count < 4096,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 || $0 == 35 }) else { return nil }
        let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first, !code.isEmpty else { return nil }
        let state = parts.count > 1 ? String(parts[1]) : ""
        return .code(String(code), state)
    }
}

/// What the App keeps after sign-in. The access token is deliberately absent: it is exchanged on
/// demand from the refresh token and never written anywhere.
struct ClaudeCredential: Codable, Equatable {
    var refreshToken: String
    var obtainedAt: Date
}

enum ClaudeStore {
    static let id = "claude-personal"
    /// Deliberately a new namespace: build 19 and earlier stored a scraped claude.ai session
    /// cookie here. The two values are different kinds of secret with no migration path, so the
    /// legacy record is deleted (see `invalidateLegacyCredential`) instead of being mistaken for
    /// an OAuth refresh token. No credential is ever copied into shared storage.
    static let service = "CodexUsage.Claude.oauth.v1"
    static let legacyService = "CodexUsage.Claude.session.v1"
    private static func query(widget: Bool = SharedStorage.isWidget) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: id]
        if widget, let group = SharedStorage.permittedGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }
    static func installed() -> Bool {
        var q = query(widget: false); q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func credentialGroup() -> String? {
        guard let group = SharedStorage.permittedGroup else { return nil }
        var q = query(widget: false); q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]], rows.count == 1,
              rows[0][kSecAttrAccessGroup as String] as? String == group else { return nil }
        return group
    }
    static func saveCredential(_ value: ClaudeCredential, widget: Bool = SharedStorage.isWidget) throws {
        // The extension may persist a rotated refresh token only under the same sharing
        // permission that let it read the credential.
        if widget && !DashboardStore.canRefresh(id, provider: "claude") { throw ClaudeFailure.storage }
        let encoded = try JSONEncoder().encode(value)
        let attrs: [String: Any] = [kSecValueData as String: encoded,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(widget: widget) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(widget: widget).merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClaudeFailure.storage }
    }
    static func credential(widget: Bool) throws -> ClaudeCredential {
        if widget && !DashboardStore.canRefresh(id, provider: "claude") { throw ClaudeFailure.storage }
        var q = query(widget: widget); q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(ClaudeCredential.self, from: data) else {
            throw status == errSecItemNotFound ? ClaudeFailure.loginRequired : ClaudeFailure.storage
        }
        return value
    }
    /// Deletes the pre-OAuth record written by the removed web-session path, plus its snapshot, so
    /// no dead third-party session cookie stays on the device. Returns true when something was
    /// removed, which is what the panel reports to the user.
    static func invalidateLegacyCredential() -> Bool {
        guard !SharedStorage.isWidget else { return false }
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: legacyService, kSecAttrAccount as String: id]
        let removed = SecItemDelete(legacy as CFDictionary) == errSecSuccess
        if let url = try? snapshotURL(), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = try? WidgetRefreshAttempt.url(id), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return removed
    }
    static func snapshotURL() throws -> URL { try SharedStorage.snapshotURL("claude:" + id).appendingPathExtension("quota") }
    static func snapshot() -> ClaudeSnapshot? {
        guard let url = try? snapshotURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeSnapshot.self, from: data)
    }
    static func save(_ value: ClaudeSnapshot) throws {
        try JSONEncoder().encode(value).write(to: snapshotURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove() throws {
        guard !SharedStorage.isWidget else { throw ClaudeFailure.storage }
        let status = SecItemDelete(query(widget: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeFailure.storage }
        let url = try snapshotURL()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct ClaudeAPI {
    let transport: any HTTPTransport
    init(transport: any HTTPTransport = URLTransport()) { self.transport = transport }

    static func validatedRefreshToken(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw ClaudeFailure.unauthorized }
        return value
    }

    struct Tokens { let accessToken: String; let refreshToken: String? }

    /// POST the authorize-code grant. PKCE only — the CLI client is public and no client secret is
    /// involved; the verifier, the exact redirect URI and the state are all required.
    func exchange(code: String, verifier: String, state: String, redirectURI: String) async throws -> Tokens {
        try await token(payload: ["grant_type": "authorization_code", "code": code,
                                  "client_id": ClaudeOAuth.clientID, "code_verifier": verifier,
                                  "redirect_uri": redirectURI, "state": state])
    }
    /// POST the refresh grant. The response may carry a rotated refresh token.
    func refreshToken(_ refresh: String) async throws -> Tokens {
        try await token(payload: ["grant_type": "refresh_token", "client_id": ClaudeOAuth.clientID,
                                  "refresh_token": try Self.validatedRefreshToken(refresh)])
    }

    private func token(payload: [String: String]) async throws -> Tokens {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: ClaudeOAuth.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(request, unauthorized: [400, 401, 403])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty else { throw ClaudeFailure.malformed }
        let rotated = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Tokens(accessToken: access, refreshToken: rotated)
    }

    /// GET the account usage windows with the OAuth bearer token.
    func usage(accessToken: String) async throws -> ClaudeSnapshot {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: ClaudeOAuth.usageEndpoint)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request, unauthorized: [401, 403])
        return try Self.parseUsage(data)
    }

    private func send(_ request: URLRequest, unauthorized codes: Set<Int>) async throws -> Data {
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ClaudeFailure.network }
        switch status {
        case 200: break
        case let code where codes.contains(code): throw ClaudeFailure.unauthorized
        case 429: throw ClaudeFailure.busy
        default: throw ClaudeFailure.unavailable
        }
        guard data.count < 1_000_000 else { throw ClaudeFailure.malformed }
        return data
    }

    /// Tolerant read of the real response shape: `five_hour` / `seven_day`, each with the used
    /// share, and a reset timestamp. A window whose used share cannot be read stays present with a
    /// nil remaining value (`—`), and a response with no usable window for either period is an
    /// error rather than a fabricated 0%.
    static func parseUsage(_ data: Data) throws -> ClaudeSnapshot {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeFailure.malformed }
        let five = window(object["five_hour"])
        let seven = window(object["seven_day"])
        guard five?.remaining != nil || seven?.remaining != nil else { throw ClaudeFailure.malformed }
        return ClaudeSnapshot(fiveHour: five, sevenDay: seven, updatedAt: Date())
    }
    private static func window(_ raw: Any?) -> ClaudeWindow? {
        guard let object = raw as? [String: Any] else { return nil }
        let used = number(object["utilization"]) ?? number(object["used_percent"])
        let remaining = used.flatMap { $0.isFinite && (0...100).contains($0) ? 100 - $0 : nil }
        let reset = (object["resets_at"] as? String).flatMap(date)
        return ClaudeWindow(remaining: remaining, reset: reset)
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

actor ClaudeService {
    static let shared = ClaudeService()
    let api: ClaudeAPI
    init(api: ClaudeAPI = ClaudeAPI()) { self.api = api }

    /// App-only: store the refresh token of a completed sign-in. The access token is discarded.
    func install(refreshToken: String) throws {
        guard !SharedStorage.isWidget else { throw ClaudeFailure.storage }
        let lease = try CredentialLease(account: ClaudeStore.id); defer { withExtendedLifetime(lease) {} }
        try ClaudeStore.saveCredential(ClaudeCredential(refreshToken: try ClaudeAPI.validatedRefreshToken(refreshToken),
                                                        obtainedAt: Date()))
    }
    func remove() throws {
        guard !SharedStorage.isWidget else { throw ClaudeFailure.storage }
        let lease = try CredentialLease(account: ClaudeStore.id); defer { withExtendedLifetime(lease) {} }
        try ClaudeStore.remove()
    }
    func refresh(widget: Bool = SharedStorage.isWidget) async throws -> ClaudeSnapshot {
        if widget && !DashboardStore.canRefresh(ClaudeStore.id, provider: "claude") { throw ClaudeFailure.storage }
        let lease = try CredentialLease(account: ClaudeStore.id); defer { withExtendedLifetime(lease) {} }
        var attempt = WidgetRefreshAttempt.load(ClaudeStore.id)
        attempt.recoverInterrupted(Date())
        if widget && !attempt.allows(Date()) {
            try attempt.save(ClaudeStore.id)
            if let cache = ClaudeStore.snapshot() { return cache }
            throw ClaudeFailure.busy
        }
        attempt.begin(Date()); try attempt.save(ClaudeStore.id)
        do {
            let credential = try ClaudeStore.credential(widget: widget)
            let tokens = try await api.refreshToken(credential.refreshToken)
            if let rotated = tokens.refreshToken, rotated != credential.refreshToken {
                // Persist a rotation before using the new token; the App always, the extension
                // only under the permission that let it read. Never re-persist the old value.
                let updated = ClaudeCredential(refreshToken: rotated, obtainedAt: Date())
                if widget { try? ClaudeStore.saveCredential(updated, widget: true) }
                else { try ClaudeStore.saveCredential(updated) }
            }
            let value = try await api.usage(accessToken: tokens.accessToken)
            try Task.checkCancellation()
            try ClaudeStore.save(value)
            attempt.succeed(Date()); try attempt.save(ClaudeStore.id)
            return value
        } catch {
            attempt.fail(Date()); try? attempt.save(ClaudeStore.id)
            if error is CancellationError { throw CancellationError() }
            throw (error as? ClaudeFailure) ?? ClaudeFailure.storage
        }
    }
}
