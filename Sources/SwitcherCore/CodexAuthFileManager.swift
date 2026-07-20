import Foundation

public final class CodexAuthFileManager {
    public let authURL: URL

    public init(authURL: URL? = nil) {
        if let authURL {
            self.authURL = authURL
        } else {
            self.authURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
    }

    public func readCurrent() throws -> Data {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw SwitcherError.authFileMissing(authURL.path)
        }
        do {
            let data = try Data(contentsOf: authURL)
            _ = try CodexAuthInspector.inspect(data)
            return data
        } catch let error as SwitcherError {
            throw error
        } catch {
            throw SwitcherError.fileOperation(error.localizedDescription)
        }
    }

    public func currentIdentity() throws -> CodexIdentity {
        try CodexAuthInspector.inspect(readCurrent())
    }

    public func writeCurrent(_ data: Data) throws {
        _ = try CodexAuthInspector.inspect(data)
        let directory = authURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: authURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authURL.path
            )
        } catch {
            throw SwitcherError.fileOperation(error.localizedDescription)
        }
    }
}
