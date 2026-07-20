import AppKit
import Foundation

public enum CodexBinaryLocator {
    public static func locate() -> URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) {
            let candidate = appURL
                .appendingPathComponent("Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

public final class CodexProbeService {
    private let binaryURL: URL?

    public init(binaryURL: URL? = nil) {
        self.binaryURL = binaryURL
    }

    public func probe(authData: Data, timeout: TimeInterval = 18) throws -> ProbeResult {
        let localIdentity = try CodexAuthInspector.inspect(authData)
        guard let binaryURL = binaryURL ?? CodexBinaryLocator.locate() else {
            throw SwitcherError.codexBinaryMissing
        }

        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAccountSwitcher-\(UUID().uuidString)", isDirectory: true)
        let temporaryAuthURL = temporaryHome.appendingPathComponent("auth.json")

        do {
            try FileManager.default.createDirectory(
                at: temporaryHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try authData.write(to: temporaryAuthURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryAuthURL.path
            )
        } catch {
            throw SwitcherError.fileOperation(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let collector = ProtocolResponseCollector(expectedIDs: [1, 2])
        let errorCollector = TextCollector(limit: 16_384)

        process.executableURL = binaryURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = temporaryHome.path
        environment["NO_COLOR"] = "1"
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.accept(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.accept(handle.availableData)
        }
        process.terminationHandler = { _ in
            collector.processEnded()
        }

        do {
            try process.run()
            let requests = Self.protocolRequests()
            try inputPipe.fileHandleForWriting.write(contentsOf: requests)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw SwitcherError.appServer(error.localizedDescription)
        }

        let completed = collector.wait(timeout: timeout)

        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let refreshedData: Data?
        if let candidate = try? Data(contentsOf: temporaryAuthURL),
           (try? CodexAuthInspector.inspect(candidate)) != nil {
            refreshedData = candidate
        } else {
            refreshedData = nil
        }

        let accountResponse = collector.response(for: 1)
        let quotaResponse = collector.response(for: 2)
        let stderr = errorCollector.text

        if let accountError = Self.errorMessage(in: accountResponse) {
            return ProbeResult(
                health: Self.isRevokedAuthentication(accountError)
                    ? .expired
                    : Self.localFallbackHealth(identity: localIdentity),
                errorMessage: Self.friendlyErrorMessage(accountError),
                refreshedAuthData: refreshedData
            )
        }

        guard
            let accountResult = accountResponse?["result"] as? [String: Any],
            let account = accountResult["account"] as? [String: Any]
        else {
            let message: String
            if !completed {
                message = "检测超时"
            } else if !stderr.isEmpty {
                message = Self.friendlyErrorMessage(stderr)
            } else {
                message = "未返回已登录账号"
            }
            return ProbeResult(
                health: Self.isRevokedAuthentication(message)
                    ? .expired
                    : Self.localFallbackHealth(identity: localIdentity),
                errorMessage: message,
                refreshedAuthData: refreshedData
            )
        }

        let email = account["email"] as? String ?? localIdentity.email
        let plan = account["planType"] as? String ?? localIdentity.planType
        var health: AccountHealth = .available
        var quota: QuotaSnapshot?
        var quotaError: String?

        if let error = Self.errorMessage(in: quotaResponse) {
            let friendly = Self.friendlyErrorMessage(error)
            quotaError = "额度读取失败：\(friendly)"
            if Self.isRevokedAuthentication(error) {
                health = .expired
            }
        } else if
            let result = quotaResponse?["result"] as? [String: Any],
            let snapshot = result["rateLimits"] as? [String: Any]
        {
            quota = Self.parseQuota(snapshot, fallbackPlan: plan)
            if quota?.reachedReason != nil || quota?.primary?.remainingPercent == 0 {
                health = .unavailable
            }
        } else if !completed {
            quotaError = "额度读取超时"
        }

        return ProbeResult(
            health: health,
            email: email,
            planType: plan,
            quota: quota,
            errorMessage: quotaError,
            refreshedAuthData: refreshedData
        )
    }

    private static func protocolRequests() -> Data {
        let lines = [
            "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"codex-account-switcher\",\"title\":\"Codex Account Switcher\",\"version\":\"0.2.3\"},\"capabilities\":{\"experimentalApi\":true,\"requestAttestation\":false}}}",
            "{\"method\":\"initialized\"}",
            "{\"method\":\"account/read\",\"id\":1,\"params\":{\"refreshToken\":false}}",
            "{\"method\":\"account/rateLimits/read\",\"id\":2}"
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func localFallbackHealth(identity: CodexIdentity) -> AccountHealth {
        if let expiry = identity.tokenExpiry, expiry <= Date() {
            return .expired
        }
        return .unavailable
    }

    private static func isRevokedAuthentication(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("401")
            || message.contains("unauthorized")
            || message.contains("invalidated oauth token")
            || message.contains("refresh token has been revoked")
            || message.contains("authentication token is invalid")
    }

    private static func friendlyErrorMessage(_ message: String) -> String {
        guard isRevokedAuthentication(message) else {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "登录令牌已被撤销（401）。请用“添加新账号”重新授权；不要在 Codex 中退出登录。"
    }

    private static func errorMessage(in response: [String: Any]?) -> String? {
        guard let error = response?["error"] else { return nil }
        if let dictionary = error as? [String: Any] {
            if let message = dictionary["message"] as? String {
                return message
            }
            if let data = try? JSONSerialization.data(withJSONObject: dictionary),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return String(describing: error)
    }

    private static func parseQuota(
        _ snapshot: [String: Any],
        fallbackPlan: String?
    ) -> QuotaSnapshot {
        let credits = snapshot["credits"] as? [String: Any]
        return QuotaSnapshot(
            limitID: snapshot["limitId"] as? String,
            limitName: snapshot["limitName"] as? String,
            planType: snapshot["planType"] as? String ?? fallbackPlan,
            primary: parseWindow(snapshot["primary"]),
            secondary: parseWindow(snapshot["secondary"]),
            hasCredits: credits?["hasCredits"] as? Bool,
            unlimitedCredits: credits?["unlimited"] as? Bool,
            creditBalance: credits?["balance"] as? String,
            reachedReason: snapshot["rateLimitReachedType"] as? String,
            checkedAt: Date()
        )
    }

    private static func parseWindow(_ value: Any?) -> RateWindow? {
        guard
            let dictionary = value as? [String: Any],
            let used = dictionary["usedPercent"] as? NSNumber
        else {
            return nil
        }
        let duration = (dictionary["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (dictionary["resetsAt"] as? NSNumber)?.doubleValue
        return RateWindow(
            usedPercent: used.doubleValue,
            durationMinutes: duration,
            resetsAt: resetTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private final class ProtocolResponseCollector {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let expectedIDs: Set<Int>
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var didSignal = false

    init(expectedIDs: Set<Int>) {
        self.expectedIDs = expectedIDs
    }

    func accept(_ data: Data) {
        guard !data.isEmpty else {
            processEnded()
            return
        }

        lock.lock()
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let number = object["id"] as? NSNumber
            {
                responses[number.intValue] = object
            }
        }
        signalIfCompleteLocked()
        lock.unlock()
    }

    func processEnded() {
        lock.lock()
        if !didSignal {
            didSignal = true
            semaphore.signal()
        }
        lock.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else { return false }
        lock.lock()
        let complete = expectedIDs.isSubset(of: Set(responses.keys))
        lock.unlock()
        return complete
    }

    func response(for id: Int) -> [String: Any]? {
        lock.lock()
        let response = responses[id]
        lock.unlock()
        return response
    }

    private func signalIfCompleteLocked() {
        guard
            !didSignal,
            expectedIDs.isSubset(of: Set(responses.keys))
        else {
            return
        }
        didSignal = true
        semaphore.signal()
    }
}

private final class TextCollector {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func accept(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(incoming.prefix(remaining))
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let result = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.unlock()
        return result
    }
}
