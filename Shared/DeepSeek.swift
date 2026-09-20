import Foundation
import Security

struct DeepSeekBalance: Codable, Equatable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]
    enum CodingKeys: String, CodingKey { case isAvailable = "is_available", balanceInfos = "balance_infos" }
    struct BalanceInfo: Codable, Equatable {
        let currency: String
        let total: Decimal
        let granted: Decimal?
        let toppedUp: Decimal?
        enum CodingKeys: String, CodingKey {
            case currency, total = "total_balance", granted = "granted_balance", toppedUp = "topped_up_balance"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currency = try c.decode(String.self, forKey: .currency)
            func amount(_ key: CodingKeys) throws -> Decimal {
                let text = try c.decode(String.self, forKey: key)
                guard text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      text.filter({ $0.isNumber }).count <= 38,
                      let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw DeepSeekError.malformed }
                return value
            }
            total = try amount(.total)
            granted = c.contains(.granted) ? try amount(.granted) : nil
            toppedUp = c.contains(.toppedUp) ? try amount(.toppedUp) : nil
            guard ["USD", "CNY"].contains(currency) else { throw DeepSeekError.malformed }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(currency, forKey: .currency)
            try c.encode(NSDecimalNumber(decimal: total).stringValue, forKey: .total)
            try c.encodeIfPresent(granted.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .granted)
            try c.encodeIfPresent(toppedUp.map { NSDecimalNumber(decimal: $0).stringValue }, forKey: .toppedUp)
        }
    }
}

enum DeepSeekError: Error, LocalizedError {
    case invalidKey, unauthorized, rateLimited, unavailable, malformed, network, storage
    var errorDescription: String? {
        switch self {
        case .invalidKey: return "API Key 为空或包含无效字符"
        case .unauthorized: return "DeepSeek Key 无效或无权访问，请在 App 更新"
        case .rateLimited: return "DeepSeek 请求过于频繁，稍后重试"
        case .unavailable: return "DeepSeek 服务暂不可用"
        case .malformed: return "DeepSeek 余额响应格式异常"
        case .network: return "DeepSeek 网络失败，保留上次余额"
        case .storage: return "DeepSeek 钥匙串或缓存不可用，请解锁并检查签名"
        }
    }
}
struct DeepSeekAPI {
    let transport: any HTTPTransport
    init(transport: any HTTPTransport = URLTransport()) { self.transport = transport }
    static func validatedKey(_ key: String) throws -> String {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 512, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw DeepSeekError.invalidKey }
        return value
    }
    func balance(key: String) async throws -> DeepSeekBalance {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(try Self.validatedKey(key))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw DeepSeekError.network }
        try Task.checkCancellation()
        switch status {
        case 200: break
        case 401, 403: throw DeepSeekError.unauthorized
        case 429: throw DeepSeekError.rateLimited
        default: throw DeepSeekError.unavailable
        }
        do {
            let value = try JSONDecoder().decode(DeepSeekBalance.self, from: data)
            guard !value.balanceInfos.isEmpty else { throw DeepSeekError.malformed }
            return value
        } catch { throw DeepSeekError.malformed }
    }
}

struct DeepSeekSnapshot: Codable, Equatable {
    let balance: DeepSeekBalance
    let updatedAt: Date
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > 1800 || now < updatedAt }
}

