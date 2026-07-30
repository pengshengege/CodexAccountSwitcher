import Darwin
import Foundation

/// Reads and writes an unmodified Codex `auth.json` for explicit device migration.
///
/// The file is intentionally not wrapped or encrypted so Codex can consume the
/// same document directly. Callers must treat it like a password.
public enum SessionFileTransfer {
    public static let maximumFileSize = 10 * 1_024 * 1_024

    public static func read(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> Data {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > maximumFileSize {
                throw SwitcherError.invalidAuthFile("Session 文件超过 10 MB")
            }

            let data = try Data(contentsOf: url)
            guard data.count <= maximumFileSize else {
                throw SwitcherError.invalidAuthFile("Session 文件超过 10 MB")
            }
            _ = try CodexAuthInspector.inspect(data)
            return data
        } catch let error as SwitcherError {
            throw error
        } catch {
            throw SwitcherError.fileOperation(
                "无法读取 Session 文件：\(error.localizedDescription)"
            )
        }
    }

    public static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = try CodexAuthInspector.inspect(data)

        do {
            try writePrivateData(data, to: url, fileManager: fileManager)
        } catch {
            throw SwitcherError.fileOperation(
                "无法导出 Session 文件：\(error.localizedDescription)"
            )
        }
    }

    /// Creates a 0600 temporary inode in the destination directory and then
    /// atomically renames it, so credential bytes are never exposed as 0666.
    static func writePrivateData(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw posixError("无法创建私密临时文件")
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError("无法设置私密文件权限")
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: temporaryURL.path
        )
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue ?? -1
        guard permissions & 0o777 == 0o600 else {
            throw SwitcherError.fileOperation(
                "目标磁盘无法保证 Session 文件权限为 0600"
            )
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("无法写入私密临时文件")
                }
                guard written > 0 else {
                    throw SwitcherError.fileOperation(
                        "写入私密临时文件时未产生任何数据"
                    )
                }
                offset += written
            }
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("无法同步私密临时文件")
        }

        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw posixError("无法关闭私密临时文件")
        }

        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError("无法原子替换目标文件")
        }
        shouldRemoveTemporaryFile = false
    }

    private static func posixError(_ operation: String) -> SwitcherError {
        let code = errno
        let message = String(cString: strerror(code))
        return SwitcherError.fileOperation(
            "\(operation)（\(code)）：\(message)"
        )
    }
}
