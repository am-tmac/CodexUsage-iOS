import Foundation

public enum ServiceError: LocalizedError {
    case http(Int), loginRequired, expired, busy, storage(String), malformed
    public var errorDescription: String? {
        switch self {
        case .http(let status): return status == 429 ? "请求过于频繁，请稍后重试。" : "服务请求失败（HTTP \(status)）。可能需要重新登录或在 ChatGPT 设置中启用设备代码登录。"
        case .loginRequired: return "请打开 App 登录 ChatGPT。"
        case .expired: return "设备代码已过期，请重新登录。"
        case .busy: return "另一刷新正在进行，请稍后重试。"
        case .storage(let message): return "安全存储不可用：\(message)"
        case .malformed: return "服务返回了无法识别的数据。"
        }
    }
}
public struct DeviceCode: Decodable, Sendable {
    public let deviceAuthID: String
    public let userCode: String
    public let interval: Double
    enum CodingKeys: String, CodingKey { case deviceAuthID = "device_auth_id", userCode = "user_code", alias = "usercode", interval }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try c.decode(String.self, forKey: .deviceAuthID)
        userCode = try c.decodeIfPresent(String.self, forKey: .userCode) ?? c.decode(String.self, forKey: .alias)
        let number = (try? c.decode(Double.self, forKey: .interval)) ?? Double((try? c.decode(String.self, forKey: .interval)) ?? "5") ?? 5
        interval = min(60, max(1, number))
    }
}
public struct TokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresIn: Double?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", expiresIn = "expires_in" }
}
public struct Credentials: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let accountID: String?
    /// Display-only identity claim (id_token `email`, or the nested
    /// https://api.openai.com/profile.email). Read-only: never used for
    /// authentication, routing or verification. Optional, so build-5 records
    /// without it still decode.
    public let email: String?
    public let expiresAt: Date
    public init(response: TokenResponse, previous: Credentials? = nil, now: Date = Date()) throws {
        guard !response.accessToken.isEmpty, let refresh = response.refreshToken ?? previous?.refreshToken, !refresh.isEmpty else { throw ServiceError.malformed }
        accessToken = response.accessToken
        refreshToken = refresh
        let accessClaims = Self.claims(response.accessToken)
        let idClaims = Self.claims(response.idToken ?? "")
        accountID = (accessClaims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String ?? (idClaims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String ?? previous?.accountID
        email = Self.emailClaim(idClaims) ?? Self.emailClaim(accessClaims) ?? previous?.email
        expiresAt = (accessClaims?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? now.addingTimeInterval(response.expiresIn ?? 3600)
    }
    /// Claims only supply routing/expiry/display hints; never treated as signature verification.
    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func emailClaim(_ claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let value = (claims["email"] as? String) ?? (profile?["email"] as? String)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    /// Display-only identity for a record loaded from storage. Prefers the stored
    /// `email`; for records written before that field existed (build-5 era) it falls
    /// back to the claims of the access token already stored alongside it, using the
    /// same extraction rules as login. Read-only: never authentication, routing or
    /// verification, and it never triggers a refresh or any network call.
    public var displayIdentity: String? {
        Self.nonBlank(email) ?? Self.emailClaim(Self.claims(accessToken))
    }
    /// The identity to backfill, or nil when the stored value is already present or
    /// the stored token carries no usable claim (then the neutral placeholder stands).
    func recoveredDisplayIdentity() -> String? {
        guard Self.nonBlank(email) == nil else { return nil }
        return Self.emailClaim(Self.claims(accessToken))
    }
    /// Rebuilds a stored record with a recovered display identity: tokens, account and
    /// expiry are copied verbatim, so label recovery can never alter credentials.
    init(accessToken: String, refreshToken: String, accountID: String?, email: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.email = email
        self.expiresAt = expiresAt
    }
}
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
public struct URLTransport: HTTPTransport {
    public init() {}
    /// One session per process (build 28): connections and TLS sessions are reused across requests
    /// instead of paying a fresh ~1.2 s handshake to chatgpt.com / api.anthropic.com every time.
    /// Still ephemeral and cookie-less, so nothing persists to disk. A stuck request gives up after
    /// 10 s (was 20–25 s) so one slow provider cannot hold the whole refresh.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServiceError.malformed }
        return (data, response.statusCode)
    }
}
public struct AuthAPI: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLTransport()) { self.transport = transport }
    func post(_ path: String, body: [String: String], form: Bool = false) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://auth.openai.com" + path)!)
        request.httpMethod = "POST"
        request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        if form {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = body.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: safe)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)" }.joined(separator: "&").data(using: .utf8)
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await transport.send(request)
    }
    public func start() async throws -> DeviceCode {
        let (data, status) = try await post("/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID])
        guard status == 200 else { throw ServiceError.http(status) }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }
    public func pollOnce(_ code: DeviceCode) async throws -> TokenResponse? {
        let (data, status) = try await post("/api/accounts/deviceauth/token", body: ["device_auth_id": code.deviceAuthID, "user_code": code.userCode])
        if status == 403 || status == 404 { return nil }
        guard status == 200 else { throw ServiceError.http(status) }
        struct Grant: Decodable { let authorization_code: String; let code_verifier: String }
        let grant = try JSONDecoder().decode(Grant.self, from: data)
        try Task.checkCancellation()
        let (tokens, tokenStatus) = try await post("/oauth/token", body: ["grant_type": "authorization_code", "client_id": Self.clientID, "code": grant.authorization_code, "code_verifier": grant.code_verifier, "redirect_uri": "https://auth.openai.com/deviceauth/callback"], form: true)
        guard tokenStatus == 200 else { throw ServiceError.http(tokenStatus) }
        return try JSONDecoder().decode(TokenResponse.self, from: tokens)
    }
    public func complete(_ code: DeviceCode) async throws -> Credentials {
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let response = try await pollOnce(code) { return try Credentials(response: response) }
            try await Task.sleep(for: .seconds(code.interval))
        }
        throw ServiceError.expired
    }
    public func refresh(_ old: Credentials) async throws -> Credentials {
        let (data, status) = try await post("/oauth/token", body: ["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": old.refreshToken, "scope": "openid profile email"])
        guard status == 200 else { throw status == 400 || status == 401 ? ServiceError.loginRequired : ServiceError.http(status) }
        return try Credentials(response: JSONDecoder().decode(TokenResponse.self, from: data), previous: old)
    }
    /// Quota windows for the account. Same call shape the widget uses.
    public func usage(_ credentials: Credentials) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsage-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let account = credentials.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw ServiceError.http(status) }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }
}
