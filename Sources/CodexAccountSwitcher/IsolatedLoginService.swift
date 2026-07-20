import Foundation
import SwitcherCore

enum IsolatedLoginServiceError: LocalizedError {
    case alreadyRunning
    case cancelled
    case timedOut
    case loginFailed(String)
    case invalidAuthorizationURL
    case authFileMissing

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已有一个账号登录正在进行。"
        case .cancelled:
            return "已取消添加账号。"
        case .timedOut:
            return "浏览器登录已超时，请重新添加账号。"
        case .loginFailed(let message):
            return message.isEmpty
                ? "Codex 浏览器登录没有完成，请重试。"
                : "Codex 浏览器登录失败：\(message)"
        case .invalidAuthorizationURL:
            return "Codex 没有返回可信的 OpenAI 登录地址，请升级 Codex 后重试。"
        case .authFileMissing:
            return "登录完成后没有生成独立登录档，请重试。"
        }
    }
}

final class IsolatedLoginService {
    typealias AuthorizationHandler = (URL) -> Void
    typealias ProgressHandler = (String) -> Void
    typealias CompletionHandler = (Result<Data, Error>) -> Void

    private let sessionsRoot: URL
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var sessionDirectory: URL?
    private var authorizationHandler: AuthorizationHandler?
    private var progressHandler: ProgressHandler?
    private var completionHandler: CompletionHandler?
    private var stdoutBuffer = Data()
    private var collectedErrors = ""
    private var loginID: String?
    private var timeoutWorkItem: DispatchWorkItem?
    private var wasCancelled = false
    private var didFinish = false

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        sessionsRoot = root.appendingPathComponent("PendingLogins", isDirectory: true)
        removeStaleSessions()
    }

    var isRunning: Bool {
        lock.withLock { process?.isRunning == true && !didFinish }
    }

    deinit {
        timeoutWorkItem?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        if process?.isRunning == true {
            process?.terminationHandler = nil
            process?.terminate()
        }
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
    }

    func start(
        onAuthorizationReady: @escaping AuthorizationHandler,
        onProgress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) throws {
        guard !isRunning else { throw IsolatedLoginServiceError.alreadyRunning }
        guard let binaryURL = CodexBinaryLocator.locate() else {
            throw SwitcherError.codexBinaryMissing
        }

        let directory = sessionsRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SwitcherError.fileOperation(error.localizedDescription)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = [
            "-c", "cli_auth_credentials_store=\"file\"",
            "app-server", "--stdio"
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory.path
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        for key in [
            "CODEX_ACCESS_TOKEN",
            "CODEX_API_KEY",
            "OPENAI_API_KEY"
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        lock.withLock {
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.sessionDirectory = directory
            self.authorizationHandler = onAuthorizationReady
            self.progressHandler = onProgress
            self.completionHandler = completion
            stdoutBuffer = Data()
            collectedErrors = ""
            loginID = nil
            wasCancelled = false
            didFinish = false
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStandardOutput(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStandardError(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.processEnded()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            resetState()
            try? FileManager.default.removeItem(at: directory)
            throw SwitcherError.fileOperation(error.localizedDescription)
        }

        emitProgress("已创建独立登录环境，正在请求普通浏览器登录…")
        do {
            try sendProtocolMessages(Self.startupMessages())
        } catch {
            finish(
                .failure(
                    IsolatedLoginServiceError.loginFailed(
                        error.localizedDescription
                    )
                )
            )
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(IsolatedLoginServiceError.timedOut))
        }
        let shouldScheduleTimeout = lock.withLock { () -> Bool in
            guard !didFinish else { return false }
            timeoutWorkItem = timeout
            return true
        }
        if shouldScheduleTimeout {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 600,
                execute: timeout
            )
        }
    }

    func cancel() {
        let loginID = lock.withLock { () -> String? in
            wasCancelled = true
            return self.loginID
        }
        if let loginID {
            try? sendProtocolMessages([
                [
                    "method": "account/login/cancel",
                    "id": 2,
                    "params": ["loginId": loginID]
                ]
            ])
        }
        finish(.failure(IsolatedLoginServiceError.cancelled))
    }

    private func consumeStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let objects = lock.withLock { () -> [[String: Any]] in
            stdoutBuffer.append(data)
            var parsed: [[String: Any]] = []
            while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = Data(stdoutBuffer[..<newlineIndex])
                stdoutBuffer.removeSubrange(...newlineIndex)
                guard
                    !line.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any]
                else {
                    continue
                }
                parsed.append(object)
            }
            return parsed
        }
        for object in objects {
            handleProtocolObject(object)
        }
    }

    private func consumeStandardError(_ data: Data) {
        guard
            !data.isEmpty,
            let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        let text = Self.stripANSI(raw)
        lock.withLock {
            collectedErrors += text
            if collectedErrors.count > 16_384 {
                collectedErrors = String(collectedErrors.suffix(16_384))
            }
        }
    }

    private func handleProtocolObject(_ object: [String: Any]) {
        if let id = (object["id"] as? NSNumber)?.intValue {
            if let message = Self.errorMessage(in: object) {
                finish(
                    .failure(IsolatedLoginServiceError.loginFailed(message))
                )
                return
            }
            if id == 1 {
                handleLoginStartResponse(object)
            }
            return
        }

        guard
            object["method"] as? String == "account/login/completed",
            let params = object["params"] as? [String: Any]
        else {
            return
        }

        let expectedLoginID = lock.withLock { loginID }
        if
            let completedLoginID = params["loginId"] as? String,
            let expectedLoginID,
            completedLoginID != expectedLoginID
        {
            return
        }

        if params["success"] as? Bool == true {
            emitProgress("浏览器已确认登录，正在读取独立登录档…")
            loadAuthData()
        } else {
            let message = params["error"] as? String
                ?? "浏览器没有完成授权。"
            finish(
                .failure(IsolatedLoginServiceError.loginFailed(message))
            )
        }
    }

    private func handleLoginStartResponse(_ object: [String: Any]) {
        guard
            let result = object["result"] as? [String: Any],
            result["type"] as? String == "chatgpt",
            let rawURL = result["authUrl"] as? String,
            let url = URL(string: rawURL),
            Self.isTrustedAuthorizationURL(url),
            let loginID = result["loginId"] as? String,
            !loginID.isEmpty
        else {
            finish(.failure(IsolatedLoginServiceError.invalidAuthorizationURL))
            return
        }

        let handler = lock.withLock { () -> AuthorizationHandler? in
            self.loginID = loginID
            return authorizationHandler
        }
        emitProgress("普通浏览器 OAuth 已启动，等待本机回调。")
        DispatchQueue.main.async {
            handler?(url)
        }
    }

    private func loadAuthData(attempt: Int = 0) {
        let directory = lock.withLock { sessionDirectory }
        guard let directory else {
            finish(.failure(IsolatedLoginServiceError.authFileMissing))
            return
        }

        let authURL = directory.appendingPathComponent("auth.json")
        if
            let data = try? Data(contentsOf: authURL),
            (try? CodexAuthInspector.inspect(data)) != nil
        {
            finish(.success(data))
            return
        }

        guard attempt < 20 else {
            finish(.failure(IsolatedLoginServiceError.authFileMissing))
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.1
        ) { [weak self] in
            self?.loadAuthData(attempt: attempt + 1)
        }
    }

    private func processEnded() {
        let snapshot = lock.withLock {
            (
                finished: didFinish,
                cancelled: wasCancelled,
                directory: sessionDirectory,
                errors: collectedErrors
            )
        }
        guard !snapshot.finished else { return }

        if snapshot.cancelled {
            finish(.failure(IsolatedLoginServiceError.cancelled))
            return
        }
        if
            let directory = snapshot.directory,
            let data = try? Data(
                contentsOf: directory.appendingPathComponent("auth.json")
            ),
            (try? CodexAuthInspector.inspect(data)) != nil
        {
            finish(.success(data))
            return
        }

        finish(
            .failure(
                IsolatedLoginServiceError.loginFailed(
                    Self.failureSummary(snapshot.errors)
                )
            )
        )
    }

    private func sendProtocolMessages(
        _ messages: [[String: Any]]
    ) throws {
        let handle = lock.withLock { inputPipe?.fileHandleForWriting }
        guard let handle else {
            throw IsolatedLoginServiceError.loginFailed(
                "Codex 登录进程已结束。"
            )
        }

        var payload = Data()
        for message in messages {
            let line = try JSONSerialization.data(withJSONObject: message)
            payload.append(line)
            payload.append(0x0A)
        }
        try handle.write(contentsOf: payload)
    }

    private func emitProgress(_ text: String) {
        let handler = lock.withLock { progressHandler }
        DispatchQueue.main.async {
            handler?(text + "\n")
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let snapshot = lock.withLock { () -> (
            process: Process?,
            input: Pipe?,
            output: Pipe?,
            error: Pipe?,
            directory: URL?,
            completion: CompletionHandler?,
            timeout: DispatchWorkItem?
        )? in
            guard !didFinish else { return nil }
            didFinish = true
            let snapshot = (
                process,
                inputPipe,
                outputPipe,
                errorPipe,
                sessionDirectory,
                completionHandler,
                timeoutWorkItem
            )
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            sessionDirectory = nil
            authorizationHandler = nil
            progressHandler = nil
            completionHandler = nil
            stdoutBuffer = Data()
            collectedErrors = ""
            loginID = nil
            timeoutWorkItem = nil
            return snapshot
        }
        guard let snapshot else { return }

        snapshot.timeout?.cancel()
        snapshot.output?.fileHandleForReading.readabilityHandler = nil
        snapshot.error?.fileHandleForReading.readabilityHandler = nil
        try? snapshot.input?.fileHandleForWriting.close()
        snapshot.process?.terminationHandler = nil

        DispatchQueue.global(qos: .userInitiated).async {
            if snapshot.process?.isRunning == true {
                snapshot.process?.terminate()
                snapshot.process?.waitUntilExit()
            }
            if let directory = snapshot.directory {
                try? FileManager.default.removeItem(at: directory)
            }
            DispatchQueue.main.async {
                snapshot.completion?(result)
            }
        }
    }

    private func resetState() {
        lock.withLock {
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            sessionDirectory = nil
            authorizationHandler = nil
            progressHandler = nil
            completionHandler = nil
            stdoutBuffer = Data()
            collectedErrors = ""
            loginID = nil
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            wasCancelled = false
            didFinish = false
        }
    }

    private func removeStaleSessions() {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-86_400)
        for directory in directories {
            let values = try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            if values?.contentModificationDate ?? .distantPast < cutoff {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private static func startupMessages() -> [[String: Any]] {
        [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "codex-account-switcher",
                        "title": "Codex Account Switcher",
                        "version": "0.2.3"
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false
                    ]
                ]
            ],
            ["method": "initialized"],
            [
                "method": "account/login/start",
                "id": 1,
                "params": ["type": "chatgpt"]
            ]
        ]
    }

    private static func isTrustedAuthorizationURL(_ url: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }

    private static func errorMessage(in response: [String: Any]) -> String? {
        guard let error = response["error"] else { return nil }
        if let dictionary = error as? [String: Any] {
            if let message = dictionary["message"] as? String {
                return message
            }
            if
                let data = try? JSONSerialization.data(
                    withJSONObject: dictionary
                ),
                let text = String(data: data, encoding: .utf8)
            {
                return text
            }
        }
        return String(describing: error)
    }

    private static func stripANSI(_ text: String) -> String {
        let escape = String(UnicodeScalar(27))
        return text.replacingOccurrences(
            of: escape + "\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func failureSummary(_ output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " ")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
