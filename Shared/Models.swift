import Foundation

enum ResetTimestamp {
    static func text(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "HHmm" : "MdHHmm")
        return "重置 " + formatter.string(from: date)
    }
}

/// Display-only account label: "<identity> · <Plan>", e.g. "alex@example.com · Plus".
///
/// The identity is an untrusted, read-only claim taken from the OAuth id_token the
/// user already authorized; it is never used for authentication or routing. Missing
/// identity falls back to a neutral placeholder (never empty, never another
/// account's name) and a missing plan omits the suffix entirely — a plan is never
/// invented.
public enum AccountLabel {
    public static let unknownIdentity = "未命名账号"
    /// Masked form used in the shared snapshot: "alex@example.com" -> "ale***@example.com".
    public static func mask(_ identity: String) -> String {
        guard let at = identity.firstIndex(of: "@") else {
            let local = String(identity.prefix(identity.count > 3 ? 3 : 1))
            return local.isEmpty ? "***" : local + "***"
        }
        let local = String(identity[identity.startIndex..<at])
        let domain = String(identity[at...])
        guard !local.isEmpty else { return "***" + domain }
        return String(local.prefix(local.count > 3 ? 3 : 1)) + "***" + domain
    }
    /// Capitalises a reported plan value; nil/blank stays nil so callers omit it.
    public static func plan(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.prefix(1).uppercased() + String(value.dropFirst())
    }
    public static func text(identity: String?, plan: String?, masked: Bool) -> String {
        let trimmed = identity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let trimmed, !trimmed.isEmpty {
            base = masked ? mask(trimmed) : trimmed
        } else {
            base = unknownIdentity
        }
        guard let plan, !plan.isEmpty else { return base }
        return base + " · " + plan
    }
}
/// User-visible appearance choice. Stored as a plain string in the shared container so
/// the widget extension can read the same value without an App Group Keychain round trip.
public enum ThemePreference: String, CaseIterable, Codable, Sendable {
    case system, light, dark
    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天"
        case .dark: return "夜间"
        }
    }
    /// Missing, unreadable or unknown values fall back to `system`; a stored string is never
    /// allowed to fail decoding into a crash or an empty appearance.
    public static func load(from url: URL) -> ThemePreference {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = ThemePreference(rawValue: raw) else { return .system }
        return value
    }
    public func save(to url: URL) throws {
        try Data(rawValue.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public static var url: URL? { try? SharedStorage.container().appendingPathComponent("theme.txt") }
    public static func load() -> ThemePreference { url.map(load(from:)) ?? .system }
    public func save() throws {
        guard let url = Self.url else { throw ServiceError.storage("主题设置不可用") }
        try save(to: url)
    }
}

/// One refresh control can serve several accounts or providers; the same account is never
/// refreshed twice in a single user action, and empty slots are dropped instead of guessed.
public enum RefreshTargets {
    public static func unique(_ ids: [String?]) -> [String] {
        var seen = Set<String>(); var result: [String] = []
        for id in ids.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !id.isEmpty {
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetAt: TimeInterval?
    public let limitWindowSeconds: Int?
    public var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    public var resetDate: Date? { resetAt.map(Date.init(timeIntervalSince1970:)) }
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent", resetAt = "reset_at", limitWindowSeconds = "limit_window_seconds"
    }
}
/// Optional `credits` block of `GET /backend-api/wham/usage`. Every member is optional and
/// decoded leniently (string or number for amounts) so an account without credits, a partial
/// response or a snapshot written by an older build all keep decoding. A member that is absent
/// hides its row — a missing value is never rendered as 0.
public struct UsageCredits: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let overageLimitReached: Bool?
    public let balance: Decimal?
    public let currency: String?
    public let approxLocalMessages: Int?
    public let approxCloudMessages: Int?
    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits", unlimited
        case overageLimitReached = "overage_limit_reached"
        case balance, currency
        case approxLocalMessages = "approx_local_messages", approxCloudMessages = "approx_cloud_messages"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = Lenient.flag(c, .hasCredits)
        unlimited = Lenient.flag(c, .unlimited)
        overageLimitReached = Lenient.flag(c, .overageLimitReached)
        balance = Lenient.amount(c, .balance)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? nil
        approxLocalMessages = Lenient.count(c, .approxLocalMessages)
        approxCloudMessages = Lenient.count(c, .approxCloudMessages)
    }
}
/// Optional `rate_limit_reset_credits` block: how many reset credits are available.
public struct UsageResetCredits: Codable, Equatable, Sendable {
    public let availableCount: Int?
    public let applicableAvailableCount: Int?
    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count", applicableAvailableCount = "applicable_available_count"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = Lenient.count(c, .availableCount)
        applicableAvailableCount = Lenient.count(c, .applicableAvailableCount)
    }
}
/// Tolerant scalar readers: a field that arrives as a string, a number, or not at all never
/// fails the whole usage decode, and an unreadable field stays nil instead of becoming 0/false.
enum Lenient {
    static func flag<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() { case "true": return true; case "false": return false; default: return nil }
        }
        return nil
    }
    static func count<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
    static func amount<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Decimal? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key),
           let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { return value }
        if let value = try? c.decodeIfPresent(Decimal.self, forKey: key) { return value }
        return nil
    }
}
public struct UsageResponse: Codable, Equatable, Sendable {
    public let planType: String?
    public let rateLimit: RateLimit?
    public let credits: UsageCredits?
    public let rateLimitResetCredits: UsageResetCredits?
    public struct RateLimit: Codable, Equatable, Sendable {
        public let primaryWindow: UsageWindow?
        public let secondaryWindow: UsageWindow?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window", secondaryWindow = "secondary_window" }
    }
    enum CodingKeys: String, CodingKey {
        case planType = "plan_type", rateLimit = "rate_limit"
        case credits, rateLimitResetCredits = "rate_limit_reset_credits"
    }
}
/// Money formatting for balances that come back in their own currency. Fixed two decimals,
/// never a percentage (a DeepSeek or credit balance has no denominator, so a percent would be
/// invented). Unknown codes keep the code itself instead of guessing a symbol.
public enum Money {
    public static func symbol(_ currency: String?) -> String {
        switch currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CNY", "RMB": return "CN¥"
        case "USD", nil, "": return "US$"
        case let other?: return other + " "
        }
    }
    public static func text(_ amount: Decimal?, currency: String?) -> String {
        guard let amount else { return "—" }
        return symbol(currency) + fixed(amount)
    }
    public static func fixed(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? NSDecimalNumber(decimal: amount).stringValue
    }
}
/// Compact relative timestamps used by the App cards, exactly as the spec writes them:
/// `今天 20:36` / `明天 20:36` / `5天后 20:10` / `9月19日 20:10`. The App is Chinese-only, so the
/// date part uses the literal `M月d日` pattern (`Md`-templates render as `9/19` in zh_CN).
/// A missing date stays "—" instead of inventing one.
public enum RelativeTime {
    public static func text(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: date)
        let start = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        if day == start { return "今天 " + clock }
        if days == 1 { return "明天 " + clock }
        if days > 1 && days <= 7 { return "\(days)天后 " + clock }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date) + " " + clock
    }
    /// `9月14日 15:51` for the 更新时间 row.
    public static func stamp(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let usage: UsageResponse
    public let updatedAt: Date
    /// Display label written at save time. It is already masked unless the user
    /// explicitly opted in to exposing the full identity in the widget; tokens and
    /// credentials are never stored here. Optional so older snapshots still decode.
    public var accountLabel: String? = nil
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > 1800 || [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0?.resetDate }.contains { $0 <= now }
    }
}
