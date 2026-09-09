import Foundation

public struct QuotaSnapshot: Equatable {
    public var title: String
    public var remaining: Double?
    public var entitlement: Double?
    public var percentRemaining: Double?
    public var unlimited: Bool
    public var creditsUsed: Double?
    public var reset: String?
    public var plan: String?

    public static func decode(_ data: Data) throws -> QuotaSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.message("GitHub 返回了无法识别的额度响应。")
        }
        let snapshots = object["quota_snapshots"] as? [String: [String: Any]] ?? [:]
        let premium = snapshots["premium_interactions"] ?? snapshots["chat"]
        guard let quota = premium else {
            throw BridgeError.message("GitHub 未提供可识别的剩余额度字段；不会把未知额度显示成 0。")
        }
        let credits = quota["token_based_billing"] as? Bool ?? object["token_based_billing"] as? Bool ?? false
        return QuotaSnapshot(title: credits ? "GitHub credits" : snapshots["premium_interactions"] != nil ? "Premium interactions" : "Chat quota",
            remaining: (quota["quota_remaining"] as? NSNumber)?.doubleValue ?? (quota["remaining"] as? NSNumber)?.doubleValue,
            entitlement: (quota["entitlement"] as? NSNumber)?.doubleValue,
            percentRemaining: (quota["percent_remaining"] as? NSNumber)?.doubleValue,
            unlimited: quota["unlimited"] as? Bool ?? false,
            creditsUsed: credits ? (quota["credits_used"] as? NSNumber)?.doubleValue : nil,
            reset: object["quota_reset_date_utc"] as? String ?? object["quota_reset_date"] as? String,
            plan: object["copilot_plan"] as? String)
    }
}
