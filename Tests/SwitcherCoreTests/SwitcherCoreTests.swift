import Darwin
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

    func testAuthInspectorRejectsEmptyTokensObject() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [:]
        ])

        XCTAssertThrowsError(try CodexAuthInspector.inspect(data)) { error in
            guard case .invalidAuthFile = error as? SwitcherError else {
                return XCTFail("Expected invalidAuthFile, got \(error)")
            }
        }
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

    func testSessionFileTransferRoundTripsUnmodifiedAuthWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherSessionTransferTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sessionURL = directory.appendingPathComponent("codex-session.json")
        let authData = try makeChatGPTAuthData(
            accountID: "account-transfer",
            email: "transfer@example.com",
            refreshToken: "refresh-transfer",
            sessionMarker: "transfer"
        )

        try SessionFileTransfer.write(authData, to: sessionURL)

        XCTAssertEqual(try SessionFileTransfer.read(from: sessionURL), authData)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: sessionURL.path
        )
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testSessionFileTransferRejectsInvalidAuthWithoutCreatingExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherInvalidSessionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sessionURL = directory.appendingPathComponent("invalid-session.json")

        XCTAssertThrowsError(
            try SessionFileTransfer.write(Data("not an auth file".utf8), to: sessionURL)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
    }

    func testSessionFileTransferUsesPrivatePermissionsWithPermissiveUmask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherSessionUmaskTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sessionURL = directory.appendingPathComponent("codex-session.json")
        let authData = try makeAPIKeyAuthData(apiKey: "umask-session-key")
        let previousUmask = Darwin.umask(0o000)
        defer { _ = Darwin.umask(previousUmask) }

        try SessionFileTransfer.write(authData, to: sessionURL)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: sessionURL.path
        )
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
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

    func testExportSessionUsesCurrentMatchingAuthAndRefreshesVault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherExportSessionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let currentAuthData = try makeAPIKeyAuthData(apiKey: "current-session-key")
        let identity = try CodexAuthInspector.inspect(currentAuthData)
        let profile = makeProfile(identity: identity)
        let store = ProfileStore(baseDirectory: directory)
        let vault = FileAuthVault(baseDirectory: directory)
        let authFile = CodexAuthFileManager(
            authURL: directory.appendingPathComponent("current/auth.json")
        )
        let library = AccountLibrary(
            store: store,
            vault: vault,
            legacyKeychain: LegacyAuthSpy(data: Data()),
            authFile: authFile
        )
        try vault.store(Data("stale-vault-session".utf8), for: profile.id)
        try authFile.writeCurrent(currentAuthData)

        let exported = try library.exportSession(
            profileID: profile.id,
            accounts: [profile]
        )

        XCTAssertEqual(exported, currentAuthData)
        XCTAssertEqual(try vault.retrieve(for: profile.id), currentAuthData)
    }

    func testExportSessionDoesNotUseCurrentAuthWithSameEmailAndDifferentAccountID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherExportIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let savedAuthData = try makeChatGPTAuthData(
            accountID: "account-saved",
            email: "shared@example.com",
            refreshToken: "refresh-saved",
            sessionMarker: "saved"
        )
        let currentAuthData = try makeChatGPTAuthData(
            accountID: "account-current",
            email: "shared@example.com",
            refreshToken: "refresh-current",
            sessionMarker: "current"
        )
        let profile = makeProfile(
            identity: try CodexAuthInspector.inspect(savedAuthData)
        )
        let vault = FileAuthVault(baseDirectory: directory)
        let authFile = CodexAuthFileManager(
            authURL: directory.appendingPathComponent("current/auth.json")
        )
        let library = AccountLibrary(
            store: ProfileStore(baseDirectory: directory),
            vault: vault,
            legacyKeychain: LegacyAuthSpy(data: Data()),
            authFile: authFile
        )
        try vault.store(savedAuthData, for: profile.id)
        try authFile.writeCurrent(currentAuthData)

        let exported = try library.exportSession(
            profileID: profile.id,
            accounts: [profile]
        )

        XCTAssertEqual(exported, savedAuthData)
        XCTAssertNotEqual(exported, currentAuthData)
        XCTAssertEqual(try vault.retrieve(for: profile.id), savedAuthData)
    }

    func testImportAndActivateSessionDeduplicatesAccountAndWritesCurrentAuth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherImportSessionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldAuthData = try makeChatGPTAuthData(
            accountID: "account-migrated",
            email: "migration@example.com",
            refreshToken: "refresh-old",
            sessionMarker: "old"
        )
        let importedAuthData = try makeChatGPTAuthData(
            accountID: "account-migrated",
            email: "migration@example.com",
            refreshToken: "refresh-new",
            sessionMarker: "new"
        )
        let oldIdentity = try CodexAuthInspector.inspect(oldAuthData)
        var existingProfile = makeProfile(identity: oldIdentity)
        existingProfile.displayName = "保留的账号名称"

        let store = ProfileStore(baseDirectory: directory)
        let vault = FileAuthVault(baseDirectory: directory)
        let authFile = CodexAuthFileManager(
            authURL: directory.appendingPathComponent("current/auth.json")
        )
        let library = AccountLibrary(
            store: store,
            vault: vault,
            legacyKeychain: LegacyAuthSpy(data: Data()),
            authFile: authFile
        )
        try store.save([existingProfile])
        try vault.store(oldAuthData, for: existingProfile.id)
        try authFile.writeCurrent(oldAuthData)

        let outcome = try library.importAndActivateSession(
            importedAuthData,
            into: [existingProfile]
        )

        XCTAssertTrue(outcome.replacedExistingProfile)
        XCTAssertFalse(outcome.createdSafetyBackup)
        XCTAssertEqual(outcome.accounts.count, 1)
        XCTAssertEqual(outcome.importedProfile.id, existingProfile.id)
        XCTAssertEqual(outcome.importedProfile.displayName, "保留的账号名称")
        XCTAssertEqual(
            outcome.importedProfile.fingerprint,
            CodexAuthInspector.fingerprint(importedAuthData)
        )
        XCTAssertEqual(try authFile.readCurrent(), importedAuthData)
        XCTAssertEqual(try vault.retrieve(for: existingProfile.id), importedAuthData)
        let persistedAccounts = try store.load()
        XCTAssertEqual(persistedAccounts.count, 1)
        XCTAssertEqual(persistedAccounts.first?.id, existingProfile.id)
        XCTAssertEqual(
            persistedAccounts.first?.fingerprint,
            CodexAuthInspector.fingerprint(importedAuthData)
        )
        XCTAssertEqual(
            library.activeProfileID(in: outcome.accounts),
            existingProfile.id
        )
    }

    func testImportAndActivateSessionDoesNotMergeSameEmailWithDifferentAccountID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherImportIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let existingAuthData = try makeChatGPTAuthData(
            accountID: "account-existing",
            email: "shared@example.com",
            refreshToken: "refresh-existing",
            sessionMarker: "existing"
        )
        let importedAuthData = try makeChatGPTAuthData(
            accountID: "account-imported",
            email: "shared@example.com",
            refreshToken: "refresh-imported",
            sessionMarker: "imported"
        )
        var existingProfile = makeProfile(
            identity: try CodexAuthInspector.inspect(existingAuthData)
        )
        existingProfile.displayName = "原账号"

        let store = ProfileStore(baseDirectory: directory)
        let vault = FileAuthVault(baseDirectory: directory)
        let authFile = CodexAuthFileManager(
            authURL: directory.appendingPathComponent("current/auth.json")
        )
        let library = AccountLibrary(
            store: store,
            vault: vault,
            legacyKeychain: LegacyAuthSpy(data: Data()),
            authFile: authFile
        )
        try store.save([existingProfile])
        try vault.store(existingAuthData, for: existingProfile.id)

        let outcome = try library.importAndActivateSession(
            importedAuthData,
            into: [existingProfile]
        )

        XCTAssertFalse(outcome.replacedExistingProfile)
        XCTAssertEqual(outcome.accounts.count, 2)
        XCTAssertNotEqual(outcome.importedProfile.id, existingProfile.id)
        XCTAssertEqual(
            outcome.importedProfile.accountIdentifier,
            "account-imported"
        )
        XCTAssertEqual(
            outcome.accounts.first(where: { $0.id == existingProfile.id })?
                .accountIdentifier,
            "account-existing"
        )
        XCTAssertEqual(try vault.retrieve(for: existingProfile.id), existingAuthData)
        XCTAssertEqual(
            try vault.retrieve(for: outcome.importedProfile.id),
            importedAuthData
        )
        XCTAssertEqual(try authFile.readCurrent(), importedAuthData)
        XCTAssertEqual(try store.load().count, 2)
    }

    func testImportAndActivateSessionRollsBackStoreAndVaultWhenActivationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitcherImportRollbackTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldAuthData = try makeChatGPTAuthData(
            accountID: "account-rollback",
            email: "rollback@example.com",
            refreshToken: "refresh-old",
            sessionMarker: "old"
        )
        let importedAuthData = try makeChatGPTAuthData(
            accountID: "account-rollback",
            email: "rollback@example.com",
            refreshToken: "refresh-new",
            sessionMarker: "new"
        )
        var existingProfile = makeProfile(
            identity: try CodexAuthInspector.inspect(oldAuthData)
        )
        existingProfile.displayName = "回滚前账号"

        let store = ProfileStore(baseDirectory: directory)
        let vault = FileAuthVault(baseDirectory: directory)
        try store.save([existingProfile])
        try vault.store(oldAuthData, for: existingProfile.id)
        let originalAccounts = try store.load()

        let blockedParentURL = directory.appendingPathComponent("blocked-parent")
        try Data("ordinary file".utf8).write(to: blockedParentURL)
        let authFile = CodexAuthFileManager(
            authURL: blockedParentURL.appendingPathComponent("auth.json")
        )
        let library = AccountLibrary(
            store: store,
            vault: vault,
            legacyKeychain: LegacyAuthSpy(data: Data()),
            authFile: authFile
        )

        XCTAssertThrowsError(
            try library.importAndActivateSession(
                importedAuthData,
                into: originalAccounts
            )
        )

        XCTAssertEqual(try vault.retrieve(for: existingProfile.id), oldAuthData)
        let restoredAccounts = try store.load()
        XCTAssertEqual(restoredAccounts.count, 1)
        XCTAssertEqual(restoredAccounts.first?.id, existingProfile.id)
        XCTAssertEqual(restoredAccounts.first?.displayName, "回滚前账号")
        XCTAssertEqual(
            restoredAccounts.first?.fingerprint,
            CodexAuthInspector.fingerprint(oldAuthData)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: authFile.authURL.path)
        )
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

    private func makeAPIKeyAuthData(apiKey: String = "fixture-key") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "api_key",
            "OPENAI_API_KEY": apiKey
        ])
    }

    private func makeChatGPTAuthData(
        accountID: String,
        email: String,
        refreshToken: String,
        sessionMarker: String
    ) throws -> Data {
        let token = try makeUnsignedJWT(payload: [
            "email": email,
            "sub": "user-\(accountID)",
            "session_marker": sessionMarker,
            "exp": 4_102_444_800,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
                "chatgpt_account_id": accountID
            ]
        ])
        return try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": token,
                "access_token": token,
                "refresh_token": refreshToken,
                "account_id": accountID
            ]
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
