import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Identifiable {
    case codex, copilot, local
    public var id: String { rawValue }
    public var title: String {
        switch self { case .codex: return "Codex"; case .copilot: return "Copilot"; case .local: return "Local" }
    }
}

public struct DeclaredCapabilities: Codable, Equatable {
    public var vision: Bool?
    public var tools: Bool?
    public var parallelTools: Bool?
    public var reasoning: Bool?
    public var search: String?
}

public struct SourceModel: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var contextWindow: Int64?
    public var fingerprint: String?
    public var declared: DeclaredCapabilities?
}

public struct SourceStatus: Codable, Equatable, Identifiable {
    public var id: UsageProvider
    public var enabled: Bool
    public var state: String
    public var message: String?
    public var observedAt: String?
    public var stale: Bool
    public var models: [SourceModel]
}

public struct CodexLoginState: Codable, Equatable {
    public var state: String
    public var message: String?
    public var url: String?
    public var code: String?
    public var awaitingCode: Bool?
    public var canCancel: Bool?
    public var accountFingerprint: String?
    public var accountLabel: String?
}

public struct GatewaySnapshot: Codable, Equatable {
    public var providers: [SourceStatus]
    public var codexLogin: CodexLoginState?
    public var refreshing: Bool
    public init() { providers = []; codexLogin = nil; refreshing = false }
}

public struct CodexQuota: Codable, Equatable {
    public struct Window: Codable, Equatable, Identifiable {
        public var id: String
        public var usedPercent: Double
        public var durationSeconds: Double?
        public var resetsAt: Double?
        public var remainingPercent: Double? {
            usedPercent.isFinite ? min(100, max(0, 100 - usedPercent)) : nil
        }
        public var title: String {
            guard let seconds = durationSeconds, seconds.isFinite, seconds > 0 else {
                return id == "primary" ? "Primary" : "Secondary"
            }
            if seconds == 604800 { return "Weekly" }
            if seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400))d" }
            return "\(Int(seconds / 3600))h"
        }
    }
    public struct Credits: Codable, Equatable {
        public var unlimited: Bool
        public var balance: String?
    }
    public var provider: String
    public var observedAt: String
    public var scope: String
    public var accountFingerprint: String?
    public var plan: String?
    public var windows: [Window]
    public var credits: Credits?
}
