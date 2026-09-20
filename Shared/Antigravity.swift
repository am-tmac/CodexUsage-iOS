import CryptoKit
import Foundation
import Security

/// Google Antigravity usage. The IDE (and CLIProxyAPI, which this follows) reads it from the Code
/// Assist backend: exchange the stored Google refresh token at oauth2.googleapis.com, then POST
/// `v1internal:loadCodeAssist` with `metadata.ideType = ANTIGRAVITY`. The reply carries the paid
/// tier and its credits; `v1internal:retrieveUserQuota` adds the per-model quota buckets when the
/// account has them. Anything the backend does not send stays nil — this type never invents a
/// fraction.
struct AntigravityQuota: Codable, Equatable, Identifiable {
    let label: String
    /// 0…100 remaining, straight from `remainingFraction`.
    let remaining: Double?
    let reset: Date?
    var id: String { label }
}

struct AntigravityUsage: Codable, Equatable {
    /// `planInfo.planType` (falls back to `paidTier.id`), e.g. "g1-pro-tier".
    let tier: String?
    /// `availablePromptCredits` from loadCodeAssist.
    let availableCredits: Double?
    /// `planInfo.monthlyPromptCredits` — the window the credits are counted against.
    let monthlyCredits: Double?
    /// Per-model quota rows, read from `fetchAvailableModels` (`models[].quotaInfo`).
    let quotas: [AntigravityQuota]

    enum CodingKeys: String, CodingKey {
        case tier, availableCredits = "available_credits", monthlyCredits = "monthly_credits", quotas
    }
    init(tier: String?, availableCredits: Double?, monthlyCredits: Double?, quotas: [AntigravityQuota]) {
        self.tier = tier; self.availableCredits = availableCredits
        self.monthlyCredits = monthlyCredits; self.quotas = quotas
    }
    /// Only answered when the API reported credits at all.
    var hasCredits: Bool? { availableCredits.map { $0 > 0 } }
    /// Antigravity splits its quota into two shared pools (Gemini models share one, every
    /// non-Gemini model — Claude, GPT-OSS … — shares the other), and model rows inside a pool
    /// report the same fraction. Collapsing them into one row per pool is what the IDE shows;
    /// each row keeps the *tightest* remaining and the earliest reset so nothing is overstated.
    var pools: [AntigravityQuota] {
        var groups: [String: [AntigravityQuota]] = [:]
        for quota in quotas {
            let key = quota.label.lowercased().contains("gemini") ? "Gemini 池" : "Claude · 其他池"
            groups[key, default: []].append(quota)
        }
        return groups.map { key, rows in
            AntigravityQuota(label: key,
                             remaining: rows.compactMap(\.remaining).min(),
                             reset: rows.compactMap(\.reset).min())
        }.sorted { ($0.label == "Gemini 池" ? 0 : 1) < ($1.label == "Gemini 池" ? 0 : 1) }
    }
    /// Tightest remaining across every reported pool — the closest thing to a single总用量 the
    /// API gives, labelled as such in the UI instead of pretending to be one number.
    var tightestRemaining: Double? { quotas.compactMap(\.remaining).min() }
    /// "可用 320 / 1000（32%）" style line, built only from reported numbers.
    var creditLine: String? {
        guard let available = availableCredits else { return nil }
        func trim(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value) }
        guard let monthly = monthlyCredits, monthly > 0 else { return trim(available) }
        let percent = Int((available / monthly * 100).rounded())
        return "\(trim(available)) / \(trim(monthly))（剩余 \(percent)%）"
    }
}

enum AntigravityError: Error, LocalizedError {
    case invalidToken, unauthorized, rateLimited, unavailable, malformed, network, storage
    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Antigravity 刷新令牌为空或包含无效字符"
        case .unauthorized: return "Antigravity 刷新令牌无效或已过期，请重新登录后更新"
        case .rateLimited: return "Antigravity 请求过于频繁，稍后重试"
        case .unavailable: return "Antigravity 服务暂不可用"
        case .malformed: return "Antigravity 用量响应格式异常"
        case .network: return "Antigravity 网络失败，保留上次用量"
        case .storage: return "Antigravity 钥匙串或缓存不可用，请解锁并检查签名"
        }
    }
}

struct AntigravityAPI {
    let transport: any HTTPTransport
    init(transport: any HTTPTransport = URLTransport()) { self.transport = transport }

    /// Antigravity is optional in public builds. Supply an OAuth client through local build
    /// settings (`ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET`) instead of committing a
    /// third-party application's credentials.
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "AntigravityClientID") as? String ?? ""
    static let clientSecret = Bundle.main.object(forInfoDictionaryKey: "AntigravityClientSecret") as? String ?? ""
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    /// The backend rejects requests without the IDE's user agent.
    static let userAgent = "antigravity/hub/1.23.2 darwin/arm64"

    static func validatedToken(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw AntigravityError.invalidToken }
        return value
    }

    /// Exchange the stored refresh token for a short-lived access token.
    func accessToken(refreshToken: String) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "client_id", value: Self.clientID),
                           URLQueryItem(name: "client_secret", value: Self.clientSecret),
                           URLQueryItem(name: "refresh_token", value: try Self.validatedToken(refreshToken)),
                           URLQueryItem(name: "grant_type", value: "refresh_token")]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AntigravityError.network }
        switch status {
        case 200: break
        case 400, 401, 403: throw AntigravityError.unauthorized
        case 429: throw AntigravityError.rateLimited
        default: throw AntigravityError.unavailable
        }
        guard let token = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty else { throw AntigravityError.malformed }
        return access
    }

    func usage(refreshToken: String) async throws -> AntigravityUsage {
        let access = try await accessToken(refreshToken: refreshToken)
        let assist = try await loadCodeAssist(accessToken: access)
        try Task.checkCancellation()
        let quotas = try await availableModels(accessToken: access, project: assist.project)
        try Task.checkCancellation()
        return AntigravityUsage(tier: assist.tier, availableCredits: assist.availableCredits,
                                monthlyCredits: assist.monthlyCredits, quotas: quotas)
    }

    /// POST /v1internal:loadCodeAssist — plan plus the prompt-credit window.
    func loadCodeAssist(accessToken: String) async throws -> (tier: String?, availableCredits: Double?, monthlyCredits: Double?, project: String?) {
        let payload = try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        let data = try await post(path: "/v1internal:loadCodeAssist", accessToken: accessToken, payload: payload)
        let assist = Self.parseAssist(data)
        return (assist.tier, assist.availableCredits, assist.monthlyCredits, Self.parseProject(data))
    }

    /// POST /v1internal:fetchAvailableModels — the per-model quota the IDE draws its bars from.
    /// A 403 here is normal for some accounts (the credits from loadCodeAssist still stand).
    func availableModels(accessToken: String, project: String?) async throws -> [AntigravityQuota] {
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        let payload = try JSONSerialization.data(withJSONObject: body)
        guard let data = try? await post(path: "/v1internal:fetchAvailableModels", accessToken: accessToken, payload: payload) else { return [] }
        return Self.parseModels(data)
    }

    /// Tolerant reader for loadCodeAssist: prompt credits come from `availablePromptCredits` /
    /// `planInfo.monthlyPromptCredits`, and the plan name from `planInfo.planType`. The older
    /// `paidTier` shape is still read as a fallback.
    static func parseAssist(_ data: Data) -> (tier: String?, availableCredits: Double?, monthlyCredits: Double?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let planInfo = root?["planInfo"] as? [String: Any]
        let paid = root?["paidTier"] as? [String: Any]
        let plan = (planInfo?["planType"] as? String) ?? (paid?["id"] as? String)
        var available = number(root?["availablePromptCredits"])
        let monthly = number(planInfo?["monthlyPromptCredits"])
        if available == nil, let credits = paid?["availableCredits"] as? [[String: Any]] {
            for credit in credits where (credit["creditType"] as? String)?.uppercased() == "GOOGLE_ONE_AI" {
                available = number(credit["creditAmount"])
                break
            }
        }
        return (plan.flatMap { $0.isEmpty ? nil : $0 }, available, monthly)
    }

    /// The code-assist project id, used when asking for the model list.
    static func parseProject(_ data: Data) -> String? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let value = root?["cloudaicompanionProject"] as? String, !value.isEmpty { return value }
        if let object = root?["cloudaicompanionProject"] as? [String: Any] {
            for key in ["id", "projectId", "name"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Tolerant reader for `models` (object keyed by id, or an array): only rows with a
    /// `quotaInfo.remainingFraction` become meters, and internal/feature-only models are skipped
    /// the same way the community tools skip them.
    static func parseModels(_ data: Data) -> [AntigravityQuota] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var rows: [AntigravityQuota] = []
        func add(id: String, model: [String: Any]) {
            guard !Self.isInternalModel(id, model) else { return }
            guard let quota = model["quotaInfo"] as? [String: Any], let fraction = number(quota["remainingFraction"]) else { return }
            let label = (model["displayName"] as? String) ?? (model["label"] as? String) ?? id
            rows.append(AntigravityQuota(label: label, remaining: min(max(fraction, 0), 1) * 100,
                                         reset: (quota["resetTime"] as? String).flatMap(date)))
        }
        if let map = root?["models"] as? [String: Any] {
            for (id, value) in map { if let model = value as? [String: Any] { add(id: id, model: model) } }
        } else if let array = root?["models"] as? [[String: Any]] {
            for model in array {
                let id = (model["modelId"] as? String) ?? (model["id"] as? String) ?? (model["displayName"] as? String) ?? ""
                add(id: id, model: model)
            }
        }
        return rows.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func isInternalModel(_ id: String, _ model: [String: Any]) -> Bool {
        let name = (model["displayName"] as? String) ?? (model["label"] as? String) ?? ""
        if id.hasPrefix("chat_") || id.hasPrefix("tab_") || id.hasPrefix("rev") { return true }
        if id.contains("image") || id.contains("mquery") || id.contains("lite") { return true }
        return name.isEmpty
    }

    /// Tolerant bucket reader for the older quota endpoint (kept for accounts that only answer
    /// that one): a labelled bucket with a fraction becomes a row.
    static func parseQuotas(_ data: Data) -> [AntigravityQuota] {
        let buckets = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["buckets"] as? [[String: Any]] ?? []
        return buckets.compactMap { bucket in
            let label = (bucket["modelId"] as? String) ?? (bucket["tokenType"] as? String)
            guard let label, !label.isEmpty, let fraction = number(bucket["remainingFraction"]) else { return nil }
            return AntigravityQuota(label: label, remaining: min(max(fraction, 0), 1) * 100,
                                    reset: (bucket["resetTime"] as? String).flatMap(date))
        }
    }

    /// Exchange the authorization code from the loopback redirect. Returns the refresh token, which
    /// is the only thing the App keeps — the access token is never stored.
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: Self.clientID),
                           URLQueryItem(name: "client_secret", value: Self.clientSecret),
                           URLQueryItem(name: "code", value: try Self.validatedToken(code)),
                           URLQueryItem(name: "code_verifier", value: verifier),
                           URLQueryItem(name: "grant_type", value: "authorization_code"),
                           URLQueryItem(name: "redirect_uri", value: redirectURI)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AntigravityError.network }
        switch status {
        case 200: break
        case 400, 401, 403: throw AntigravityError.unauthorized
        case 429: throw AntigravityError.rateLimited
        default: throw AntigravityError.unavailable
        }
        guard let token = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let refresh = token["refresh_token"] as? String, !refresh.isEmpty else { throw AntigravityError.malformed }
        return refresh
    }

    private func post(path: String, accessToken: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com" + path)!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = payload
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AntigravityError.network }
        try Task.checkCancellation()
        switch status {
        case 200: break
        case 401, 403: throw AntigravityError.unauthorized
        case 429: throw AntigravityError.rateLimited
        default: throw AntigravityError.unavailable
        }
        return data
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static func date(_ text: String) -> Date? { formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) }
}

struct AntigravitySnapshot: Codable, Equatable {
    let usage: AntigravityUsage
    let updatedAt: Date
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > 1800 || now < updatedAt }
}


// MARK: - Keychain + snapshot store (App-only provider: the widget shows Codex and DeepSeek only)

enum AntigravityStore {
    static let service = "CodexUsage.Antigravity.refresh-token.v1"
    static let account = "antigravity"
    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func saveToken(_ token: String) throws {
        guard !SharedStorage.isWidget else { throw AntigravityError.storage }
        let value = try AntigravityAPI.validatedToken(token)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query().merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AntigravityError.storage }
    }
    static func token() throws -> String? {
        if SharedStorage.isWidget && !DashboardStore.canRefresh(account, provider: "antigravity") { throw AntigravityError.storage }
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AntigravityError.storage }
        return value
    }
    static func installed() -> Bool { (try? token()) ?? nil != nil }
    static func snapshotURL() throws -> URL { try SharedStorage.snapshotURL("antigravity").appendingPathExtension("usage") }
    static func snapshot() -> AntigravitySnapshot? {
        guard let url = try? snapshotURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AntigravitySnapshot.self, from: data)
    }
    static func save(_ value: AntigravitySnapshot) throws {
        try JSONEncoder().encode(value).write(to: snapshotURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove() throws {
        guard !SharedStorage.isWidget else { throw AntigravityError.storage }
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AntigravityError.storage }
        if let url = try? snapshotURL(), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

actor AntigravityService {
    static let shared = AntigravityService()
    let api: AntigravityAPI
    init(api: AntigravityAPI = AntigravityAPI()) { self.api = api }
    func install(token: String) throws {
        let lease = try CredentialLease(account: AntigravityStore.account); defer { withExtendedLifetime(lease) {} }
        try AntigravityStore.saveToken(token)
    }
    func remove() throws {
        let lease = try CredentialLease(account: AntigravityStore.account); defer { withExtendedLifetime(lease) {} }
        try AntigravityStore.remove()
    }
    func refresh(token: String? = nil) async throws -> AntigravitySnapshot {
        try Task.checkCancellation()
        guard let token = try token ?? AntigravityStore.token() else { throw AntigravityError.unauthorized }
        let usage = try await api.usage(refreshToken: token)
        let value = AntigravitySnapshot(usage: usage, updatedAt: Date())
        try AntigravityStore.save(value)
        return value
    }
}


// MARK: - Sign-in support (loopback OAuth, same client the IDE ships)

/// Google accepts only a loopback redirect for this client: a custom scheme is rejected with
/// `invalid_request` (verified against accounts.google.com). So the App runs a tiny local listener
/// and shows the consent page in an in-app browser; the redirect lands on 127.0.0.1 and the code
/// never leaves the device.
enum AntigravityOAuth {
    static let scopes = ["https://www.googleapis.com/auth/cloud-platform",
                         "https://www.googleapis.com/auth/userinfo.email",
                         "https://www.googleapis.com/auth/userinfo.profile",
                         "https://www.googleapis.com/auth/cclog",
                         "https://www.googleapis.com/auth/experimentsandconfigs"]
    /// 51121 is the port the desktop IDE registers; Google allows any port for a loopback client,
    /// so a busy port can fall back to another one.
    static let preferredPort: UInt16 = 51121
    static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/oauth2callback" }

    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
    static func codeChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
    static func authorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [URLQueryItem(name: "client_id", value: AntigravityAPI.clientID),
                                 URLQueryItem(name: "redirect_uri", value: redirectURI),
                                 URLQueryItem(name: "response_type", value: "code"),
                                 URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                                 URLQueryItem(name: "code_challenge", value: challenge),
                                 URLQueryItem(name: "code_challenge_method", value: "S256"),
                                 URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "access_type", value: "offline"),
                                 URLQueryItem(name: "prompt", value: "consent")]
        return components.url!
    }

    /// Parse only the expected callback path and require the one-time OAuth state before accepting
    /// either a code or an error. A local process cannot forge a callback from an older login.
    enum Callback: Equatable { case code(String), failure(String) }
    static func parseCallback(_ requestLine: String, expectedState: String) -> Callback? {
        guard let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost" + target),
              components.path == "/oauth2callback" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return nil }
        if let error = value("error"), !error.isEmpty { return .failure(error) }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        return nil
    }
}

extension Data {
    /// base64url without padding, as PKCE and JWT-style payloads require.
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
