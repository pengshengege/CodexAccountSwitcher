import Foundation
import Security

public struct ImportOutcome: Sendable {
    public var accounts: [AccountProfile]
    public var importedProfile: AccountProfile
    public var replacedExistingProfile: Bool
}

public struct SwitchOutcome: Sendable {
    public var accounts: [AccountProfile]
    public var activeProfile: AccountProfile
    public var createdSafetyBackup: Bool
}

public final class AccountLibrary {
    public let store: ProfileStore
    public let vault: FileAuthVault
    public let legacyKeychain: LegacyAuthRetrieving
    public let authFile: CodexAuthFileManager
    public let probeService: CodexProbeService

    public init(
        store: ProfileStore = ProfileStore(),
        vault: FileAuthVault? = nil,
        legacyKeychain: LegacyAuthRetrieving = KeychainVault(),
        authFile: CodexAuthFileManager = CodexAuthFileManager(),
        probeService: CodexProbeService = CodexProbeService()
    ) {
        self.store = store
        self.vault = vault ?? FileAuthVault(
            baseDirectory: store.applicationSupportDirectory
        )
        self.legacyKeychain = legacyKeychain
        self.authFile = authFile
        self.probeService = probeService
    }

    public func loadAccounts() throws -> [AccountProfile] {
        try store.load()
    }

    public func activeProfileID(in accounts: [AccountProfile]) -> UUID? {
        guard
            let data = try? authFile.readCurrent(),
            let identity = try? CodexAuthInspector.inspect(data)
        else {
            return nil
        }

        if let accountID = identity.accountIdentifier,
           let match = accounts.first(where: { $0.accountIdentifier == accountID }) {
            return match.id
        }
        return accounts.first(where: { $0.fingerprint == identity.fingerprint })?.id
    }

    public func currentIdentity() -> CodexIdentity? {
        try? authFile.currentIdentity()
    }

    public func importCurrent(into accounts: [AccountProfile]) throws -> ImportOutcome {
        let data = try authFile.readCurrent()
        return try importAuthData(data, into: accounts)
    }

    public func importAuthData(
        _ data: Data,
        into accounts: [AccountProfile]
    ) throws -> ImportOutcome {
        let identity = try CodexAuthInspector.inspect(data)
        var updated = accounts

        if let index = matchingIndex(for: identity, in: updated) {
            var profile = updated[index]
            profile.email = identity.email ?? profile.email
            profile.accountIdentifier = identity.accountIdentifier ?? profile.accountIdentifier
            profile.authMode = identity.authMode
            profile.planType = identity.planType ?? profile.planType
            profile.fingerprint = identity.fingerprint
            profile.importedAt = Date()
            profile.health = .unchecked
            profile.lastError = nil
            try vault.store(data, for: profile.id)
            updated[index] = profile
            try store.save(updated)
            return ImportOutcome(
                accounts: updated,
                importedProfile: profile,
                replacedExistingProfile: true
            )
        }

        let profile = AccountProfile(
            displayName: CodexAuthInspector.suggestedDisplayName(for: identity),
            email: identity.email,
            accountIdentifier: identity.accountIdentifier,
            authMode: identity.authMode,
            planType: identity.planType,
            fingerprint: identity.fingerprint
        )
        try vault.store(data, for: profile.id)
        updated.append(profile)

        do {
            try store.save(updated)
        } catch {
            try? vault.delete(for: profile.id)
            throw error
        }
        return ImportOutcome(
            accounts: updated,
            importedProfile: profile,
            replacedExistingProfile: false
        )
    }

    public func switchTo(
        profileID: UUID,
        accounts: [AccountProfile]
    ) throws -> SwitchOutcome {
        guard let target = accounts.first(where: { $0.id == profileID }) else {
            throw SwitcherError.profileNotFound
        }

        var updated = accounts
        var createdSafetyBackup = false

        if let currentData = try? authFile.readCurrent(),
           let currentIdentity = try? CodexAuthInspector.inspect(currentData) {
            if let currentIndex = matchingIndex(for: currentIdentity, in: updated) {
                var currentProfile = updated[currentIndex]
                currentProfile.email = currentIdentity.email ?? currentProfile.email
                currentProfile.planType = currentIdentity.planType ?? currentProfile.planType
                currentProfile.accountIdentifier = currentIdentity.accountIdentifier
                    ?? currentProfile.accountIdentifier
                currentProfile.fingerprint = currentIdentity.fingerprint
                try vault.store(currentData, for: currentProfile.id)
                updated[currentIndex] = currentProfile
            } else {
                let backup = AccountProfile(
                    displayName: "自动备份 · \(CodexAuthInspector.suggestedDisplayName(for: currentIdentity))",
                    email: currentIdentity.email,
                    accountIdentifier: currentIdentity.accountIdentifier,
                    authMode: currentIdentity.authMode,
                    planType: currentIdentity.planType,
                    fingerprint: currentIdentity.fingerprint
                )
                try vault.store(currentData, for: backup.id)
                updated.append(backup)
                createdSafetyBackup = true
            }
        }

        let targetData = try storedAuthData(
            for: target.id,
            allowLegacyMigration: true
        )
        try authFile.writeCurrent(targetData)
        try store.save(updated)

        let refreshedTarget = updated.first(where: { $0.id == target.id }) ?? target
        return SwitchOutcome(
            accounts: updated,
            activeProfile: refreshedTarget,
            createdSafetyBackup: createdSafetyBackup
        )
    }

    public func check(
        profileID: UUID,
        accounts: [AccountProfile]
    ) throws -> (accounts: [AccountProfile], result: ProbeResult) {
        guard let index = accounts.firstIndex(where: { $0.id == profileID }) else {
            throw SwitcherError.profileNotFound
        }

        let savedProfile = accounts[index]
        let authData: Data
        let usedCurrentAuthFile: Bool
        if let currentData = try? authFile.readCurrent(),
           let currentIdentity = try? CodexAuthInspector.inspect(currentData),
           identity(currentIdentity, matches: savedProfile) {
            authData = currentData
            usedCurrentAuthFile = true
            try vault.store(currentData, for: profileID)
        } else {
            authData = try storedAuthData(
                for: profileID,
                allowLegacyMigration: false
            )
            usedCurrentAuthFile = false
        }
        let result = try probeService.probe(authData: authData)
        var updated = accounts
        var profile = updated[index]

        profile.health = result.health
        profile.lastCheckedAt = Date()
        profile.lastError = result.errorMessage
        profile.email = result.email ?? profile.email
        profile.planType = result.planType ?? result.quota?.planType ?? profile.planType
        profile.quota = result.quota ?? profile.quota

        let newestAuthData = result.refreshedAuthData
            ?? (usedCurrentAuthFile ? authData : nil)
        if let newestAuthData,
           let newestIdentity = try? CodexAuthInspector.inspect(newestAuthData) {
            try vault.store(newestAuthData, for: profileID)
            profile.fingerprint = newestIdentity.fingerprint
            profile.accountIdentifier = newestIdentity.accountIdentifier
                ?? profile.accountIdentifier
            profile.email = newestIdentity.email ?? profile.email
            profile.planType = newestIdentity.planType ?? profile.planType

            if usedCurrentAuthFile,
               result.refreshedAuthData != nil,
               let stillCurrent = try? authFile.currentIdentity(),
               identity(stillCurrent, matches: profile) {
                try authFile.writeCurrent(newestAuthData)
            }
        }

        updated[index] = profile
        try store.save(updated)
        return (updated, result)
    }

    public func rename(
        profileID: UUID,
        to name: String,
        accounts: [AccountProfile]
    ) throws -> [AccountProfile] {
        guard let index = accounts.firstIndex(where: { $0.id == profileID }) else {
            throw SwitcherError.profileNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SwitcherError.invalidAuthFile("账号名称不能为空")
        }

        var updated = accounts
        updated[index].displayName = trimmed
        try store.save(updated)
        return updated
    }

    public func delete(
        profileID: UUID,
        accounts: [AccountProfile]
    ) throws -> [AccountProfile] {
        guard accounts.contains(where: { $0.id == profileID }) else {
            throw SwitcherError.profileNotFound
        }
        let updated = accounts.filter { $0.id != profileID }
        try store.save(updated)
        try vault.delete(for: profileID)
        return updated
    }

    private func matchingIndex(
        for identity: CodexIdentity,
        in accounts: [AccountProfile]
    ) -> Int? {
        if let accountID = identity.accountIdentifier,
           let index = accounts.firstIndex(where: { $0.accountIdentifier == accountID }) {
            return index
        }
        if let index = accounts.firstIndex(where: { $0.fingerprint == identity.fingerprint }) {
            return index
        }
        if let email = identity.email,
           let index = accounts.firstIndex(where: {
               $0.email?.caseInsensitiveCompare(email) == .orderedSame
           }) {
            return index
        }
        return nil
    }

    private func identity(
        _ identity: CodexIdentity,
        matches profile: AccountProfile
    ) -> Bool {
        if let accountID = identity.accountIdentifier,
           let profileAccountID = profile.accountIdentifier,
           accountID == profileAccountID {
            return true
        }
        if let email = identity.email,
           let profileEmail = profile.email,
           email.caseInsensitiveCompare(profileEmail) == .orderedSame {
            return true
        }
        return identity.fingerprint == profile.fingerprint
    }

    private func storedAuthData(
        for profileID: UUID,
        allowLegacyMigration: Bool
    ) throws -> Data {
        if vault.contains(profileID) {
            return try vault.retrieve(for: profileID)
        }

        guard allowLegacyMigration else {
            throw SwitcherError.storedAuthMissing
        }

        do {
            let legacyData = try legacyKeychain.retrieve(for: profileID)
            try vault.store(legacyData, for: profileID)
            return legacyData
        } catch let error as SwitcherError {
            if case .keychain(let status) = error,
               status == errSecItemNotFound {
                throw SwitcherError.storedAuthMissing
            }
            throw error
        }
    }
}
