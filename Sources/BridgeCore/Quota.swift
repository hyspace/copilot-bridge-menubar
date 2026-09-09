import Foundation
import CoreFoundation

public enum QuotaKind: String, Codable { case credits, premiumInteractions, chat }

public struct QuotaSnapshot: Codable, Equatable {
    public var kind: QuotaKind
    public var title: String {
        switch kind {
        case .credits: return "GitHub credits"
        case .premiumInteractions: return "Premium interactions"
        case .chat: return "Chat quota"
        }
    }
    public var remaining: Double?
    public var entitlement: Double?
    public var percentRemaining: Double?
    public var unlimited: Bool
    public var creditsUsed: Double?
    public var reset: String?
    public var plan: String?

    public static func decode(_ data: Data) throws -> QuotaSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.message("GitHub returned an unrecognized quota response.")
        }
        let snapshots = object["quota_snapshots"] as? [String: [String: Any]] ?? [:]
        let premium = snapshots["premium_interactions"] ?? snapshots["chat"]
        guard let quota = premium else {
            throw BridgeError.message("GitHub did not return a supported quota field. The balance is unknown, not zero.")
        }
        let credits = quota["token_based_billing"] as? Bool ?? object["token_based_billing"] as? Bool ?? false
        func number(_ key: String) -> Double? {
            guard let value = quota[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        return QuotaSnapshot(kind: credits ? .credits : snapshots["premium_interactions"] != nil ? .premiumInteractions : .chat,
            remaining: number("quota_remaining") ?? number("remaining"),
            entitlement: number("entitlement"),
            percentRemaining: number("percent_remaining"),
            unlimited: quota["unlimited"] as? Bool ?? false,
            creditsUsed: credits ? number("credits_used") : nil,
            reset: object["quota_reset_date_utc"] as? String ?? object["quota_reset_date"] as? String,
            plan: object["copilot_plan"] as? String)
    }
}
