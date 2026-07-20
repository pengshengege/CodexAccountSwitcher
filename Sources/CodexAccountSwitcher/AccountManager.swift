import AppKit
import Foundation
import SwitcherCore

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum IsolatedLoginPhase: Equatable {
    case starting
    case waitingForAuthorization
    case importing
    case completed
    case failed
}

struct IsolatedLoginState: Identifiable {
    let id = UUID()
    var phase: IsolatedLoginPhase = .starting
    var authorizationURL: URL?
    var output = ""
    var completionMessage: String?
    var errorMessage: String?

    var isWorking: Bool {
        phase == .starting || phase == .waitingForAuthorization || phase == .importing
    }
}

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var accounts: [AccountProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var currentIdentity: CodexIdentity?
    @Published private(set) var checkingIDs: Set<UUID> = []
    @Published private(set) var isImporting = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var switchingProfileID: UUID?
    @Published private(set) var quotaNotificationsEnabled: Bool
    @Published private(set) var notificationStatusText = "正在读取…"
    @Published private(set) var notificationUsesCompatibilityMode = false
    @Published private(set) var lastAutomaticRefreshAt: Date?
    @Published private(set) var isolatedLoginState: IsolatedLoginState?
    @Published var pendingRestart = false
    @Published var notice: AppNotice?
    @Published var autoRestart: Bool {
        didSet {
            UserDefaults.standard.set(
                autoRestart,
                forKey: Self.autoRestartDefaultsKey
            )
        }
    }
    @Published var quotaAlertThreshold: Double {
        didSet {
            UserDefaults.standard.set(
                quotaAlertThreshold,
                forKey: Self.quotaAlertThresholdDefaultsKey
            )
            synchronizeAllNotifications()
        }
    }
    @Published var automaticRefreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(
                automaticRefreshMinutes,
                forKey: Self.automaticRefreshDefaultsKey
            )
            configureRefreshTimer()
        }
    }

    let library: AccountLibrary
    let appController: CodexApplicationController
    let notificationService: QuotaNotificationService
    let isolatedLoginService: IsolatedLoginService

    private static let autoRestartDefaultsKey = "autoRestartCodexAfterSwitch"
    private static let notificationsEnabledDefaultsKey = "quotaNotificationsEnabled"
    private static let quotaAlertThresholdDefaultsKey = "quotaAlertThreshold"
    private static let automaticRefreshDefaultsKey = "automaticRefreshMinutes"
    private var refreshTimer: Timer?

    init(
        library: AccountLibrary = AccountLibrary()
    ) {
        self.library = library
        self.appController = CodexApplicationController()
        self.notificationService = QuotaNotificationService()
        self.isolatedLoginService = IsolatedLoginService(
            baseDirectory: library.store.applicationSupportDirectory
        )
        autoRestart = UserDefaults.standard.bool(
            forKey: Self.autoRestartDefaultsKey
        )
        quotaNotificationsEnabled = UserDefaults.standard.bool(
            forKey: Self.notificationsEnabledDefaultsKey
        )
        quotaAlertThreshold = UserDefaults.standard.object(
            forKey: Self.quotaAlertThresholdDefaultsKey
        ) as? Double ?? 20
        let savedRefreshMinutes = UserDefaults.standard.integer(
            forKey: Self.automaticRefreshDefaultsKey
        )
        automaticRefreshMinutes = savedRefreshMinutes > 0 ? savedRefreshMinutes : 15
        reloadFromDisk()
        configureRefreshTimer()
        Task {
            await updateNotificationStatus()
            if quotaNotificationsEnabled {
                synchronizeAllNotifications()
            }
        }
    }

    func reloadFromDisk() {
        do {
            accounts = try library.loadAccounts()
            refreshCurrentIdentity()
        } catch {
            showError(error)
        }
    }

    func importCurrent() {
        guard !isImporting else { return }
        isImporting = true
        let snapshot = accounts
        let library = library

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try library.importCurrent(into: snapshot)
                }.value
                accounts = outcome.accounts
                refreshCurrentIdentity()
                isImporting = false
                notice = AppNotice(
                    title: outcome.replacedExistingProfile ? "账号已更新" : "导入成功",
                    message: "\(outcome.importedProfile.displayName) 的登录信息已保存到仅当前用户可读的本机私密存储。"
                )
                check(outcome.importedProfile.id)
            } catch {
                isImporting = false
                showError(error)
            }
        }
    }

    func beginIsolatedLogin() {
        guard isolatedLoginState?.isWorking != true else { return }
        isolatedLoginState = IsolatedLoginState()

        do {
            try isolatedLoginService.start(
                onAuthorizationReady: { [weak self] url in
                    self?.receiveIsolatedAuthorizationURL(url)
                },
                onProgress: { [weak self] text in
                    self?.consumeIsolatedLoginProgress(text)
                },
                completion: { [weak self] result in
                    self?.finishIsolatedLogin(result)
                }
            )
        } catch {
            failIsolatedLogin(error)
        }
    }

    func cancelIsolatedLogin() {
        isolatedLoginService.cancel()
        isolatedLoginState = nil
    }

    func dismissIsolatedLogin() {
        guard isolatedLoginState?.isWorking != true else { return }
        isolatedLoginState = nil
    }

    func openIsolatedLoginPage() {
        guard let url = isolatedLoginState?.authorizationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyIsolatedLoginLink() {
        guard let url = isolatedLoginState?.authorizationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func switchTo(_ profileID: UUID) {
        guard switchingProfileID == nil, activeProfileID != profileID else { return }
        switchingProfileID = profileID
        let snapshot = accounts
        let library = library

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try library.switchTo(profileID: profileID, accounts: snapshot)
                }.value
                accounts = outcome.accounts
                activeProfileID = outcome.activeProfile.id
                currentIdentity = library.currentIdentity()

                if autoRestart {
                    try await appController.restartCodex()
                    pendingRestart = false
                    switchingProfileID = nil
                    notice = AppNotice(
                        title: "切换完成",
                        message: "已切换到 \(outcome.activeProfile.displayName)，Codex 已重新启动。"
                    )
                } else {
                    pendingRestart = appController.isRunning
                    switchingProfileID = nil
                    let backupText = outcome.createdSafetyBackup
                        ? " 切换前的未归档账号也已自动备份。"
                        : ""
                    notice = AppNotice(
                        title: "账号已写入",
                        message: appController.isRunning
                            ? "重启 Codex 后将使用 \(outcome.activeProfile.displayName)。\(backupText)"
                            : "下次打开 Codex 时将使用 \(outcome.activeProfile.displayName)。\(backupText)"
                    )
                }
            } catch {
                switchingProfileID = nil
                showError(error)
            }
        }
    }

    func check(_ profileID: UUID) {
        guard !checkingIDs.contains(profileID) else { return }
        checkingIDs.insert(profileID)
        let snapshot = accounts
        let library = library

        Task {
            do {
                let outcome = try await Task.detached(priority: .utility) {
                    try library.check(profileID: profileID, accounts: snapshot)
                }.value
                accounts = outcome.accounts
                checkingIDs.remove(profileID)
                refreshCurrentIdentity()
                synchronizeNotifications(for: profileID)
            } catch {
                checkingIDs.remove(profileID)
                if requiresStoredAuthMigration(error) {
                    notice = AppNotice(
                        title: "请先切换一次",
                        message: "这个账号仍在旧版钥匙串中。后台检测不会读取它；主动切换到该账号一次即可完成迁移，系统最多只会在这次迁移时请求授权。"
                    )
                    return
                }
                markCheckFailure(profileID, message: error.localizedDescription)
                showError(error)
            }
        }
    }

    func refreshAll(isAutomatic: Bool = false) {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true

        Task {
            var working = accounts
            for profile in working {
                if isAutomatic && profileNeedsReauthorization(profile) {
                    continue
                }
                checkingIDs.insert(profile.id)
                do {
                    let library = library
                    let profileID = profile.id
                    let snapshot = working
                    let outcome = try await Task.detached(priority: .utility) {
                        try library.check(profileID: profileID, accounts: snapshot)
                    }.value
                    working = outcome.accounts
                    accounts = working
                    synchronizeNotifications(for: profileID)
                } catch {
                    if !requiresStoredAuthMigration(error),
                       let index = working.firstIndex(where: { $0.id == profile.id }) {
                        working[index].health = .unavailable
                        working[index].lastCheckedAt = Date()
                        working[index].lastError = error.localizedDescription
                    }
                    accounts = working
                }
                checkingIDs.remove(profile.id)
            }
            isRefreshingAll = false
            if isAutomatic {
                lastAutomaticRefreshAt = Date()
            }
            refreshCurrentIdentity()
        }
    }

    func rename(_ profileID: UUID, to name: String) {
        do {
            accounts = try library.rename(
                profileID: profileID,
                to: name,
                accounts: accounts
            )
            synchronizeNotifications(for: profileID)
        } catch {
            showError(error)
        }
    }

    func delete(_ profileID: UUID) {
        do {
            accounts = try library.delete(profileID: profileID, accounts: accounts)
            if activeProfileID == profileID {
                activeProfileID = nil
            }
            Task {
                await notificationService.removeNotifications(for: profileID)
            }
        } catch {
            showError(error)
        }
    }

    func openCodex() {
        do {
            try appController.openCodex()
        } catch {
            showError(error)
        }
    }

    func restartCodex() {
        Task {
            do {
                try await appController.restartCodex()
                pendingRestart = false
            } catch {
                showError(error)
            }
        }
    }

    func revealDataDirectory() {
        let directory = library.store.applicationSupportDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func setQuotaNotificationsEnabled(_ enabled: Bool) {
        if !enabled {
            quotaNotificationsEnabled = false
            UserDefaults.standard.set(
                false,
                forKey: Self.notificationsEnabledDefaultsKey
            )
            refreshTimer?.invalidate()
            refreshTimer = nil
            notificationService.removeAllNotifications()
            Task { await updateNotificationStatus() }
            return
        }

        Task {
            do {
                let granted = try await notificationService.requestAuthorization()
                quotaNotificationsEnabled = granted
                UserDefaults.standard.set(
                    granted,
                    forKey: Self.notificationsEnabledDefaultsKey
                )
                await updateNotificationStatus()
                if granted {
                    configureRefreshTimer()
                    synchronizeAllNotifications()
                    refreshAll()
                } else {
                    notice = AppNotice(
                        title: "通知权限未开启",
                        message: "请在“系统设置 → 通知”中允许 Codex Account Switcher 发送通知。"
                    )
                }
            } catch {
                quotaNotificationsEnabled = false
                showError(error)
            }
        }
    }

    func sendTestNotification() {
        Task {
            do {
                let status = await notificationService.authorizationStatus()
                if status == .notDetermined {
                    let granted = try await notificationService.requestAuthorization()
                    guard granted else {
                        await updateNotificationStatus()
                        return
                    }
                    quotaNotificationsEnabled = true
                    UserDefaults.standard.set(
                        true,
                        forKey: Self.notificationsEnabledDefaultsKey
                    )
                } else if status == .denied {
                    notice = AppNotice(
                        title: "通知权限未开启",
                        message: "请在“系统设置 → 通知”中允许 Codex Account Switcher 发送通知。"
                    )
                    await updateNotificationStatus()
                    return
                }
                try await notificationService.sendTestNotification()
                await updateNotificationStatus()
            } catch {
                showError(error)
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    var authPath: String {
        library.authFile.authURL.path
    }

    var codexBinaryPath: String {
        CodexBinaryLocator.locate()?.path ?? "未找到"
    }

    var activeProfile: AccountProfile? {
        accounts.first { $0.id == activeProfileID }
    }

    var menuBarRemainingPercent: Double? {
        guard let activeProfile,
              !profileNeedsReauthorization(activeProfile),
              let quota = activeProfile.quota else {
            return nil
        }
        let values = [quota.primary, quota.secondary]
            .compactMap { $0?.remainingPercent }
        return values.min()
    }

    var activeProfileNeedsReauthorization: Bool {
        activeProfile.map(profileNeedsReauthorization) ?? false
    }

    private func refreshCurrentIdentity() {
        currentIdentity = library.currentIdentity()
        activeProfileID = library.activeProfileID(in: accounts)
    }

    private func markCheckFailure(_ profileID: UUID, message: String) {
        guard let index = accounts.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        accounts[index].health = .unavailable
        accounts[index].lastCheckedAt = Date()
        accounts[index].lastError = message
    }

    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard quotaNotificationsEnabled else { return }

        let interval = TimeInterval(max(5, automaticRefreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAll(isAutomatic: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func synchronizeNotifications(for profileID: UUID) {
        guard quotaNotificationsEnabled,
              let profile = accounts.first(where: { $0.id == profileID }) else {
            return
        }
        if profileNeedsReauthorization(profile) {
            Task {
                await notificationService.removeNotifications(for: profileID)
            }
            return
        }
        let threshold = quotaAlertThreshold
        Task {
            await notificationService.synchronize(
                profile: profile,
                threshold: threshold
            )
        }
    }

    private func synchronizeAllNotifications() {
        guard quotaNotificationsEnabled else { return }
        let profiles = accounts.filter { !profileNeedsReauthorization($0) }
        let revokedProfileIDs = accounts
            .filter(profileNeedsReauthorization)
            .map(\.id)
        let threshold = quotaAlertThreshold
        Task {
            for profileID in revokedProfileIDs {
                await notificationService.removeNotifications(for: profileID)
            }
            for profile in profiles {
                await notificationService.synchronize(
                    profile: profile,
                    threshold: threshold
                )
            }
        }
    }

    private func updateNotificationStatus() async {
        let status = await notificationService.authorizationStatus()
        notificationUsesCompatibilityMode = status == .compatibility
        switch status {
        case .notDetermined:
            notificationStatusText = "尚未请求系统权限"
        case .denied:
            notificationStatusText = "系统通知已关闭"
            quotaNotificationsEnabled = false
            UserDefaults.standard.set(
                false,
                forKey: Self.notificationsEnabledDefaultsKey
            )
            configureRefreshTimer()
        case .authorized:
            notificationStatusText = "系统通知已允许"
        case .provisional:
            notificationStatusText = "临时允许"
        case .ephemeral:
            notificationStatusText = "临时会话允许"
        case .compatibility:
            notificationStatusText = quotaNotificationsEnabled
                ? "本地兼容提醒已启用"
                : "本地兼容提醒可用"
        }
    }

    private func receiveIsolatedAuthorizationURL(_ url: URL) {
        guard var state = isolatedLoginState, state.isWorking else { return }
        state.authorizationURL = url
        state.phase = .waitingForAuthorization
        isolatedLoginState = state
        let opened = NSWorkspace.shared.open(url)
        consumeIsolatedLoginProgress(
            opened
                ? "已在默认浏览器打开登录页。"
                : "默认浏览器未能自动打开，请点击“打开登录页”。"
        )
    }

    private func consumeIsolatedLoginProgress(_ text: String) {
        guard var state = isolatedLoginState, state.isWorking else { return }
        state.output += text
        if state.output.count > 16_384 {
            state.output = String(state.output.suffix(16_384))
        }
        isolatedLoginState = state
    }

    private func finishIsolatedLogin(_ result: Result<Data, Error>) {
        guard isolatedLoginState != nil else { return }
        switch result {
        case .success(let authData):
            isolatedLoginState?.phase = .importing
            let snapshot = accounts
            let library = library
            Task {
                do {
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        try library.importAuthData(authData, into: snapshot)
                    }.value
                    accounts = outcome.accounts
                    refreshCurrentIdentity()
                    isolatedLoginState?.phase = .completed
                    isolatedLoginState?.completionMessage = outcome.replacedExistingProfile
                        ? "\(outcome.importedProfile.displayName) 已重新授权，旧的 401 登录档已更新。"
                        : "\(outcome.importedProfile.displayName) 已添加，当前 Codex 账号没有被退出。"
                    check(outcome.importedProfile.id)
                } catch {
                    failIsolatedLogin(error)
                }
            }
        case .failure(let error):
            if let loginError = error as? IsolatedLoginServiceError,
               case .cancelled = loginError {
                isolatedLoginState = nil
            } else {
                failIsolatedLogin(error)
            }
        }
    }

    private func failIsolatedLogin(_ error: Error) {
        if isolatedLoginState == nil {
            isolatedLoginState = IsolatedLoginState()
        }
        isolatedLoginState?.phase = .failed
        isolatedLoginState?.errorMessage = error.localizedDescription
    }

    private func profileNeedsReauthorization(_ profile: AccountProfile) -> Bool {
        if profile.health == .expired { return true }
        let error = profile.lastError?.lowercased() ?? ""
        return error.contains("401")
            || error.contains("unauthorized")
            || error.contains("invalidated oauth token")
            || error.contains("登录令牌已被撤销")
    }

    private func requiresStoredAuthMigration(_ error: Error) -> Bool {
        (error as? SwitcherError)?.requiresStoredAuthMigration == true
    }

    private func showError(_ error: Error) {
        notice = AppNotice(title: "操作失败", message: error.localizedDescription)
    }
}
