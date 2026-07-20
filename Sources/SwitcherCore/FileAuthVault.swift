import Foundation

/// Stores complete Codex login archives in an app-private directory.
///
/// The containing directory is limited to the current user (0700) and each
/// archive is read/write only for that user (0600). Keeping this independent
/// from Keychain ACLs also means background quota checks never trigger a
/// SecurityAgent password prompt.
public final class FileAuthVault {
    public let directoryURL: URL

    private let fileManager: FileManager

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager

        let applicationDirectory: URL
        if let baseDirectory {
            applicationDirectory = baseDirectory
        } else {
            let root = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
            applicationDirectory = root.appendingPathComponent(
                "CodexAccountSwitcher",
                isDirectory: true
            )
        }

        directoryURL = applicationDirectory.appendingPathComponent(
            "AuthVault",
            isDirectory: true
        )
    }

    public func store(_ data: Data, for profileID: UUID) throws {
        do {
            try prepareDirectory()
            let destination = fileURL(for: profileID)
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            throw SwitcherError.fileOperation(
                "无法保存账号私密登录档：\(error.localizedDescription)"
            )
        }
    }

    public func retrieve(for profileID: UUID) throws -> Data {
        let source = fileURL(for: profileID)
        guard fileManager.fileExists(atPath: source.path) else {
            throw SwitcherError.storedAuthMissing
        }

        do {
            return try Data(contentsOf: source)
        } catch {
            throw SwitcherError.fileOperation(
                "无法读取账号私密登录档：\(error.localizedDescription)"
            )
        }
    }

    public func delete(for profileID: UUID) throws {
        let destination = fileURL(for: profileID)
        guard fileManager.fileExists(atPath: destination.path) else { return }

        do {
            try fileManager.removeItem(at: destination)
        } catch {
            throw SwitcherError.fileOperation(
                "无法删除账号私密登录档：\(error.localizedDescription)"
            )
        }
    }

    public func contains(_ profileID: UUID) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: profileID).path)
    }

    public func fileURL(for profileID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            profileID.uuidString.lowercased() + ".authdata",
            isDirectory: false
        )
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        var privateDirectory = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? privateDirectory.setResourceValues(resourceValues)
    }
}
