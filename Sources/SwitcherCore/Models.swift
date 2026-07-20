import Foundation
import Security

public enum AccountHealth: String, Codable, CaseIterable, Sendable {
    case unchecked
    case available
    case unavailable
    case expired
}

public struct RateWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var durationMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, durationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var limitID: String?
    public var limitName: String?
    public var planType: String?
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var hasCredits: Bool?
    public var unlimitedCredits: Bool?
    public var creditBalance: String?
    public var reachedReason: String?
    public var checkedAt: Date

    public init(
        limitID: String? = nil,
        limitName: String? = nil,
        planType: String? = nil,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        hasCredits: Bool? = nil,
        unlimitedCredits: Bool? = nil,
        creditBalance: String? = nil,
        reachedReason: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.hasCredits = hasCredits
        self.unlimitedCredits = unlimitedCredits
        self.creditBalance = creditBalance
        self.reachedReason = reachedReason
        self.checkedAt = checkedAt
    }
}

public struct AccountProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var email: String?
    public var accountIdentifier: String?
    public var authMode: String
    public var planType: String?
    public var importedAt: Date
    public var lastCheckedAt: Date?
    public var health: AccountHealth
    public var lastError: String?
    public var quota: QuotaSnapshot?
    public var fingerprint: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        email: String?,
        accountIdentifier: String?,
        authMode: String,
        planType: String?,
        importedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        health: AccountHealth = .unchecked,
        lastError: String? = nil,
        quota: QuotaSnapshot? = nil,
        fingerprint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.accountIdentifier = accountIdentifier
        self.authMode = authMode
        self.planType = planType
        self.importedAt = importedAt
        self.lastCheckedAt = lastCheckedAt
        self.health = health
        self.lastError = lastError
        self.quota = quota
        self.fingerprint = fingerprint
    }
}

public struct CodexIdentity: Equatable, Sendable {
    public var email: String?
    public var accountIdentifier: String?
    public var planType: String?
    public var authMode: String
    public var tokenExpiry: Date?
    public var fingerprint: String

    public init(
        email: String?,
        accountIdentifier: String?,
        planType: String?,
        authMode: String,
        tokenExpiry: Date?,
        fingerprint: String
    ) {
        self.email = email
        self.accountIdentifier = accountIdentifier
        self.planType = planType
        self.authMode = authMode
        self.tokenExpiry = tokenExpiry
        self.fingerprint = fingerprint
    }
}

public struct ProbeResult: Sendable {
    public var health: AccountHealth
    public var email: String?
    public var planType: String?
    public var quota: QuotaSnapshot?
    public var errorMessage: String?
    public var refreshedAuthData: Data?

    public init(
        health: AccountHealth,
        email: String? = nil,
        planType: String? = nil,
        quota: QuotaSnapshot? = nil,
        errorMessage: String? = nil,
        refreshedAuthData: Data? = nil
    ) {
        self.health = health
        self.email = email
        self.planType = planType
        self.quota = quota
        self.errorMessage = errorMessage
        self.refreshedAuthData = refreshedAuthData
    }
}

public enum SwitcherError: LocalizedError {
    case authFileMissing(String)
    case invalidAuthFile(String)
    case storedAuthMissing
    case keychain(OSStatus)
    case profileNotFound
    case codexBinaryMissing
    case probeTimedOut
    case appServer(String)
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .authFileMissing(let path):
            return "未找到 Codex 登录文件：\(path)"
        case .invalidAuthFile(let reason):
            return "Codex 登录文件无效：\(reason)"
        case .storedAuthMissing:
            return "这个账号尚未迁移到新版本机私密存储。请先主动切换一次完成迁移；若旧登录档已失效，请重新授权。"
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "macOS 钥匙串操作失败（\(status)）：\(text)"
        case .profileNotFound:
            return "找不到这个账号档案。"
        case .codexBinaryMissing:
            return "未找到 Codex 后端。请先安装或更新 Codex macOS 应用。"
        case .probeTimedOut:
            return "账号检测超时，请检查网络后重试。"
        case .appServer(let message):
            return "Codex 账号检测失败：\(message)"
        case .fileOperation(let message):
            return "文件操作失败：\(message)"
        }
    }

    public var requiresStoredAuthMigration: Bool {
        guard case .storedAuthMissing = self else { return false }
        return true
    }
}
