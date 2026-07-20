import AppKit
import Foundation

@MainActor
final class CodexApplicationController {
    private let bundleIdentifier = "com.openai.codex"

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    func openCodex() throws {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            throw ControllerError.appNotInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration,
            completionHandler: nil
        )
    }

    func restartCodex() async throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        for application in running {
            _ = application.terminate()
        }

        for _ in 0..<20 {
            if !isRunning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        if isRunning {
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ) {
                _ = application.forceTerminate()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try openCodex()
    }

    enum ControllerError: LocalizedError {
        case appNotInstalled

        var errorDescription: String? {
            "未找到 Codex macOS 应用。"
        }
    }
}
