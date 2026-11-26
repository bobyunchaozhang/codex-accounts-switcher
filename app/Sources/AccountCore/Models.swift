import Foundation
import CryptoKit

public enum AccountError: LocalizedError {
    case message(String)
    case authenticationRejected
    case identityMismatch
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .authenticationRejected: return "登录凭证已被服务拒绝，请重新登录。"
        case .identityMismatch: return "服务返回的账号或工作区与目标不一致。"
        }
    }
}

public struct Identity: Codable, Equatable, Sendable {
    public let user: String
    public let workspace: String
    public let email: String
    public let plan: String
    public var key: String { SHA256.hash(data: Data((user + "\u{0}" + workspace).utf8)).map { String(format: "%02x", $0) }.joined() }
    public func matches(_ other: Identity) -> Bool { user == other.user && workspace == other.workspace }
    public var planLabel: String { PlanLabel.display(current: nil, stored: plan) }

}

public enum PlanLabel {
    // Mapping verified against the installed official desktop's seat-name resources (2026-11-08).
    public static func display(current: String?, stored: String) -> String {
        switch current ?? stored {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free": return "Free"
        case "self_serve_business_prolite": return "Business Premium"
        case "team", "business", "self_serve_business_usage_based": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return "订阅待确认"
        }
    }
}

public struct Credential {
    public let data: Data
    public let identity: Identity
    public let accessExpires: Date?
    public init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let id = tokens["id_token"] as? String,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let workspace = tokens["account_id"] as? String, !workspace.isEmpty,
              let claims = Self.claims(id), let user = claims["sub"] as? String, !user.isEmpty,
              let email = claims["email"] as? String, !email.isEmpty else {
            throw AccountError.message("登录资料不完整，请重新登录。")
        }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        self.data = data
        self.identity = Identity(user: user, workspace: workspace, email: email, plan: auth?["chatgpt_plan_type"] as? String ?? "unknown")
        self.accessExpires = (Self.claims(access)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
    // JWT claims identify a local record; they are not a signature or server-authentication check.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    public func withoutRefreshToken() throws -> Data {
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var tokens = root["tokens"] as! [String: Any]
        tokens["refresh_token"] = ""
        root["tokens"] = tokens
        return try JSONSerialization.data(withJSONObject: root)
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var remaining: Double { Double(max(0, min(100, 100 - usedPercent))) / 100 }
    public var label: String { windowDurationMins == 300 ? "5H" : "Weekly" }
}
public struct QuotaBucket: Codable, Sendable {
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public let planType: String?
    public var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
    public var selected: QuotaWindow? {
        windows.first { $0.windowDurationMins == 300 } ?? windows.first { $0.windowDurationMins == 10080 }
    }
}
public struct ResetCard: Codable, Sendable {
    public let id: String
    public let status: String
    public let resetType: String
    public let expiresAt: Double?
    public let expiryPresent: Bool
    enum CodingKeys: String, CodingKey { case id, status, resetType, expiresAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        resetType = try c.decode(String.self, forKey: .resetType)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        expiryPresent = c.contains(.expiresAt)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(status, forKey: .status); try c.encode(resetType, forKey: .resetType)
        if expiryPresent { if let expiresAt { try c.encode(expiresAt, forKey: .expiresAt) } else { try c.encodeNil(forKey: .expiresAt) } }
    }
}
public struct CardSummary: Codable, Sendable {
    public let availableCount: Int
    public let credits: [ResetCard]?
    public var expiryLabel: String { expiryLabel(now: Date()) }
    public func expiryLabel(now: Date) -> String {
        if availableCount == 0 { return "—" }
        guard let rows = credits, rows.count == availableCount,
              Set(rows.map(\.id)).count == availableCount,
              rows.allSatisfy({ $0.status == "available" && $0.resetType == "codexRateLimits" && $0.expiryPresent }) else { return "到期待确认" }
        if let first = rows.compactMap(\.expiresAt).min() { return DateText.remaining(first, now: now, elapsed: "已到期·待更新") }
        return "无到期日"
    }
}
public struct Usage: Codable, Sendable {
    public let accountId: String?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimits: QuotaBucket
    public let rateLimitsByLimitId: [String: QuotaBucket]?
    public let rateLimitResetCredits: CardSummary?
    public var bucket: QuotaBucket? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty { return buckets["codex"] }
        return rateLimits
    }
    public var note: String? {
        if ordinaryUsageAllowed == false { return "当前普通额度不可用" }
        if bucket?.windows.contains(where: { $0.windowDurationMins == 10080 && $0.usedPercent >= 100 }) == true { return "周额度已用完" }
        return nil
    }
}
public enum DateText {
    public static func remaining(_ seconds: Double, now: Date, elapsed: String = "待刷新") -> String {
        guard seconds.isFinite else { return "待确认" }
        let delta = seconds - now.timeIntervalSince1970
        guard delta > 0 else { return elapsed }
        guard delta >= 60 else { return "不足1分钟" }
        guard delta < Double(Int.max) else { return "待确认" }
        let minutes = Int(delta / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        return (days > 0 ? "\(days)天" : "") + (hours > 0 || days > 0 ? "\(hours)小时" : "") + "\(mins)分"
    }
    public static func absolute(_ seconds: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    public static func format(_ seconds: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}
public struct Profile: Codable, Identifiable, Sendable {
    public var id: String { identity.key }
    public var identity: Identity
    public var added: Date
    public init(identity: Identity, added: Date = Date()) { self.identity = identity; self.added = added }
}
public struct CachedUsage: Codable, Sendable {
    public let usage: Usage
    public let date: Date
    public init(usage: Usage, date: Date = Date()) { self.usage = usage; self.date = date }
}
