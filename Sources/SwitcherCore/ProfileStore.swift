import Foundation

public final class ProfileStore {
    private struct Envelope: Codable {
        var version: Int
        var accounts: [AccountProfile]
    }

    public let applicationSupportDirectory: URL
    public let metadataURL: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            applicationSupportDirectory = baseDirectory
        } else {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            applicationSupportDirectory = root.appendingPathComponent(
                "CodexAccountSwitcher",
                isDirectory: true
            )
        }
        metadataURL = applicationSupportDirectory.appendingPathComponent("accounts.json")
    }

    public func load() throws -> [AccountProfile] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return []
        }
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data).accounts
    }

    public func save(_ accounts: [AccountProfile]) throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(version: 1, accounts: accounts))
        try data.write(to: metadataURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
    }
}
