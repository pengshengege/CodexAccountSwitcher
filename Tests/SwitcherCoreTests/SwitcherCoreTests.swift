import Foundation
import XCTest
@testable import SwitcherCore

final class SwitcherCoreTests: XCTestCase {
    func testAuthInspectorExtractsIdentity() throws {
        let payload: [String: Any] = [
            "email": "demo@example.com",
            "sub": "user-123",
            "exp": 4_102_444_800,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
                "chatgpt_account_id": "account-456"
            ]
        ]
        let token = try makeUnsignedJWT(payload: payload)
        let document: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": token,
                "access_token": token,
                "refresh_token": "fixture-only",
                "account_id": "account-456"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: document)

        let identity = try CodexAuthInspector.inspect(data)

        XCTAssertEqual(identity.email, "demo@example.com")
        XCTAssertEqual(identity.accountIdentifier, "account-456")
        XCTAssertEqual(identity.planType, "plus")
        XCTAssertEqual(identity.authMode, "chatgpt")
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertEqual(
            CodexAuthInspector.suggestedDisplayName(for: identity),
            "demo"
        )
    }

    func testProfileStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProfileStore(baseDirectory: directory)
        let profile = AccountProfile(
            displayName: "测试账号",
            email: "demo@example.com",
            accountIdentifier: "account-456",
            authMode: "chatgpt",
            planType: "plus",
            fingerprint: String(repeating: "a", count: 64)
        )

        try store.save([profile])
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, profile.id)
        XCTAssertEqual(loaded.first?.displayName, profile.displayName)
        XCTAssertEqual(loaded.first?.email, profile.email)
        XCTAssertEqual(loaded.first?.fingerprint, profile.fingerprint)
    }

    func testAuthFileWritesWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherAuthTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let authURL = directory.appendingPathComponent("auth.json")
        let manager = CodexAuthFileManager(authURL: authURL)
        let document: [String: Any] = [
            "auth_mode": "api_key",
            "OPENAI_API_KEY": "fixture-key"
        ]
        let data = try JSONSerialization.data(withJSONObject: document)

        try manager.writeCurrent(data)

        XCTAssertEqual(try manager.readCurrent(), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testQuotaResetCountdownUsesDaysHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            QuotaTimeFormatter.countdown(
                until: now.addingTimeInterval(6 * 86_400 + 3 * 3_600),
                from: now
            ),
            "6 天 3 小时"
        )
        XCTAssertEqual(
            QuotaTimeFormatter.countdown(
                until: now.addingTimeInterval(2 * 3_600 + 18 * 60),
                from: now
            ),
            "2 小时 18 分钟"
        )
        XCTAssertEqual(
            QuotaTimeFormatter.countdown(
                until: now.addingTimeInterval(42 * 60),
                from: now
            ),
            "42 分钟"
        )
        XCTAssertEqual(
            QuotaTimeFormatter.countdown(
                until: now.addingTimeInterval(-1),
                from: now
            ),
            "即将重置"
        )
    }

    func testFileAuthVaultUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherVaultTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = FileAuthVault(baseDirectory: directory)
        let profileID = UUID()
        let data = Data("fixture-auth-data".utf8)

        try vault.store(data, for: profileID)
        let retrieved = try vault.retrieve(for: profileID)

        XCTAssertEqual(retrieved, data)
        XCTAssertTrue(vault.contains(profileID))

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: vault.directoryURL.path
        )
        let directoryPermissions = (
            directoryAttributes[.posixPermissions] as? NSNumber
        )?.intValue
        XCTAssertEqual(directoryPermissions, 0o700)

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: vault.fileURL(for: profileID).path
        )
        let filePermissions = (
            fileAttributes[.posixPermissions] as? NSNumber
        )?.intValue
        XCTAssertEqual(filePermissions, 0o600)

        try vault.delete(for: profileID)
        XCTAssertFalse(vault.contains(profileID))
    }

    func testBackgroundCheckNeverReadsLegacyKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherNoPromptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let authData = try makeAPIKeyAuthData()
        let identity = try CodexAuthInspector.inspect(authData)
        let profile = makeProfile(identity: identity)
        let legacyVault = LegacyAuthSpy(data: authData)
        let store = ProfileStore(baseDirectory: directory)
        let library = AccountLibrary(
            store: store,
            vault: FileAuthVault(baseDirectory: directory),
            legacyKeychain: legacyVault,
            authFile: CodexAuthFileManager(
                authURL: directory.appendingPathComponent("current/auth.json")
            )
        )

        XCTAssertThrowsError(
            try library.check(profileID: profile.id, accounts: [profile])
        ) { error in
            XCTAssertTrue(
                (error as? SwitcherError)?.requiresStoredAuthMigration == true
            )
        }
        XCTAssertEqual(legacyVault.retrieveCount, 0)
    }

    func testExplicitSwitchMigratesLegacyCredentialOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let authData = try makeAPIKeyAuthData()
        let identity = try CodexAuthInspector.inspect(authData)
        let profile = makeProfile(identity: identity)
        let legacyVault = LegacyAuthSpy(data: authData)
        let fileVault = FileAuthVault(baseDirectory: directory)
        let authFile = CodexAuthFileManager(
            authURL: directory.appendingPathComponent("current/auth.json")
        )
        let library = AccountLibrary(
            store: ProfileStore(baseDirectory: directory),
            vault: fileVault,
            legacyKeychain: legacyVault,
            authFile: authFile
        )

        _ = try library.switchTo(profileID: profile.id, accounts: [profile])

        XCTAssertEqual(legacyVault.retrieveCount, 1)
        XCTAssertEqual(try fileVault.retrieve(for: profile.id), authData)
        XCTAssertEqual(try authFile.readCurrent(), authData)

        _ = try library.switchTo(profileID: profile.id, accounts: [profile])
        XCTAssertEqual(legacyVault.retrieveCount, 1)
    }

    func testLiveCodexProbeWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_CODEX_INTEGRATION_TESTS=1 to run the live Codex probe.")
        }

        let authData = try CodexAuthFileManager().readCurrent()
        let result = try CodexProbeService().probe(authData: authData, timeout: 20)

        XCTAssertNotEqual(result.health, .expired)
        XCTAssertNotNil(result.email)
        XCTAssertNotNil(result.quota)
    }

    private func makeUnsignedJWT(payload: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let body = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URL(header)).\(base64URL(body))."
    }

    private func makeAPIKeyAuthData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "api_key",
            "OPENAI_API_KEY": "fixture-key"
        ])
    }

    private func makeProfile(identity: CodexIdentity) -> AccountProfile {
        AccountProfile(
            displayName: "旧版测试账号",
            email: identity.email,
            accountIdentifier: identity.accountIdentifier,
            authMode: identity.authMode,
            planType: identity.planType,
            fingerprint: identity.fingerprint
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LegacyAuthSpy: LegacyAuthRetrieving {
    private let data: Data
    private(set) var retrieveCount = 0

    init(data: Data) {
        self.data = data
    }

    func retrieve(for profileID: UUID) throws -> Data {
        retrieveCount += 1
        return data
    }
}
