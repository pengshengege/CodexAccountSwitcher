import AppKit
import Foundation
import Security
import SwitcherCore
import UserNotifications

enum QuotaNotificationAuthorizationStatus {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case compatibility
}

final class QuotaNotificationService: NSObject,
    UNUserNotificationCenterDelegate,
    NSUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let legacyCenter: NSUserNotificationCenter
    private let defaults: UserDefaults
    private let seenAlertIDsKey = "seenQuotaLowAlertIdentifiers"
    private let compatibilityModeKey = "quotaNotificationCompatibilityMode"

    override init() {
        center = .current()
        legacyCenter = .default
        defaults = .standard
        super.init()
        center.delegate = self
        legacyCenter.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        if shouldPreferCompatibilityMode {
            defaults.set(true, forKey: compatibilityModeKey)
            return true
        }

        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound]
            )
            if granted {
                defaults.set(false, forKey: compatibilityModeKey)
            }
            return granted
        } catch {
            guard shouldUseCompatibilityMode(for: error) else { throw error }
            // UserNotifications rejects ad-hoc signed local builds on some macOS
            // versions. The legacy local center still supports on-device alerts.
            defaults.set(true, forKey: compatibilityModeKey)
            return true
        }
    }

    func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
        if shouldPreferCompatibilityMode {
            return .compatibility
        }

        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .notDetermined
        }
    }

    func synchronize(
        profile: AccountProfile,
        threshold: Double
    ) async {
        let status = await authorizationStatus()
        if status == .compatibility {
            synchronizeLegacy(profile: profile, threshold: threshold)
            return
        }
        guard status == .authorized || status == .provisional else {
            return
        }

        let prefix = profilePrefix(profile.id)
        let pending = await center.pendingNotificationRequests()
        let staleIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)

        guard let quota = profile.quota else { return }
        let windows: [(key: String, label: String, window: RateWindow?)] = [
            ("primary", windowLabel(quota.primary), quota.primary),
            ("secondary", windowLabel(quota.secondary), quota.secondary)
        ]

        for item in windows {
            guard let window = item.window else { continue }
            await scheduleLowQuotaIfNeeded(
                profile: profile,
                window: window,
                windowKey: item.key,
                windowLabel: item.label,
                threshold: threshold
            )
            await scheduleResetIfNeeded(
                profile: profile,
                window: window,
                windowKey: item.key,
                windowLabel: item.label
            )
        }
    }

    func removeNotifications(for profileID: UUID) async {
        let prefix = profilePrefix(profileID)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map { $0.request.identifier }
            .filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        removeLegacyNotifications(withPrefix: prefix)
    }

    func removeAllNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        legacyCenter.scheduledNotifications.forEach {
            legacyCenter.removeScheduledNotification($0)
        }
        legacyCenter.removeAllDeliveredNotifications()
    }

    func sendTestNotification() async throws {
        if await authorizationStatus() == .compatibility {
            let notification = makeLegacyNotification(
                identifier: "quota-test-\(UUID().uuidString)",
                title: "额度提醒已开启",
                body: "Codex Account Switcher 会在额度偏低或窗口重置时提醒你。"
            )
            legacyCenter.deliver(notification)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "额度提醒已开启"
        content.body = "Codex Account Switcher 会在额度偏低或窗口重置时提醒你。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quota-test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    nonisolated func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func scheduleLowQuotaIfNeeded(
        profile: AccountProfile,
        window: RateWindow,
        windowKey: String,
        windowLabel: String,
        threshold: Double
    ) async {
        guard window.remainingPercent <= threshold else { return }

        let cycle = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
        let identifier = "\(profilePrefix(profile.id))low-\(windowKey)-\(cycle)-\(Int(threshold))"
        var seen = Set(defaults.stringArray(forKey: seenAlertIDsKey) ?? [])
        guard !seen.contains(identifier) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(profile.displayName) 额度偏低"
        content.body = "\(windowLabel)额度剩余 \(Int(window.remainingPercent.rounded()))%\(resetSuffix(window.resetsAt))"
        content.sound = .default
        content.userInfo = ["profileID": profile.id.uuidString]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            seen.insert(identifier)
            if seen.count > 200 {
                seen = Set(seen.sorted().suffix(200))
            }
            defaults.set(Array(seen), forKey: seenAlertIDsKey)
        } catch {
            // A failed local notification must not make account refresh fail.
        }
    }

    private func scheduleResetIfNeeded(
        profile: AccountProfile,
        window: RateWindow,
        windowKey: String,
        windowLabel: String
    ) async {
        guard let resetDate = window.resetsAt,
              resetDate.timeIntervalSinceNow > 10 else {
            return
        }

        let timestamp = Int(resetDate.timeIntervalSince1970)
        let identifier = "\(profilePrefix(profile.id))reset-\(windowKey)-\(timestamp)"
        let content = UNMutableNotificationContent()
        content.title = "\(profile.displayName) 额度已重置"
        content.body = "\(windowLabel)额度窗口已经重置，可以继续使用这个账号。"
        content.sound = .default
        content.userInfo = ["profileID": profile.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: resetDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private func synchronizeLegacy(
        profile: AccountProfile,
        threshold: Double
    ) {
        let prefix = profilePrefix(profile.id)
        legacyCenter.scheduledNotifications
            .filter { $0.identifier?.hasPrefix(prefix) == true }
            .forEach { legacyCenter.removeScheduledNotification($0) }

        guard let quota = profile.quota else { return }
        let windows: [(key: String, label: String, window: RateWindow?)] = [
            ("primary", windowLabel(quota.primary), quota.primary),
            ("secondary", windowLabel(quota.secondary), quota.secondary)
        ]

        for item in windows {
            guard let window = item.window else { continue }
            deliverLegacyLowQuotaIfNeeded(
                profile: profile,
                window: window,
                windowKey: item.key,
                windowLabel: item.label,
                threshold: threshold
            )
            scheduleLegacyResetIfNeeded(
                profile: profile,
                window: window,
                windowKey: item.key,
                windowLabel: item.label
            )
        }
    }

    private func deliverLegacyLowQuotaIfNeeded(
        profile: AccountProfile,
        window: RateWindow,
        windowKey: String,
        windowLabel: String,
        threshold: Double
    ) {
        guard window.remainingPercent <= threshold else { return }

        let cycle = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
        let identifier = "\(profilePrefix(profile.id))low-\(windowKey)-\(cycle)-\(Int(threshold))"
        var seen = Set(defaults.stringArray(forKey: seenAlertIDsKey) ?? [])
        guard !seen.contains(identifier) else { return }

        let notification = makeLegacyNotification(
            identifier: identifier,
            title: "\(profile.displayName) 额度偏低",
            body: "\(windowLabel)额度剩余 \(Int(window.remainingPercent.rounded()))%\(resetSuffix(window.resetsAt))",
            profileID: profile.id
        )
        legacyCenter.deliver(notification)
        remember(identifier, in: &seen)
    }

    private func scheduleLegacyResetIfNeeded(
        profile: AccountProfile,
        window: RateWindow,
        windowKey: String,
        windowLabel: String
    ) {
        guard let resetDate = window.resetsAt,
              resetDate.timeIntervalSinceNow > 10 else {
            return
        }

        let timestamp = Int(resetDate.timeIntervalSince1970)
        let identifier = "\(profilePrefix(profile.id))reset-\(windowKey)-\(timestamp)"
        let notification = makeLegacyNotification(
            identifier: identifier,
            title: "\(profile.displayName) 额度已重置",
            body: "\(windowLabel)额度窗口已经重置，可以继续使用这个账号。",
            profileID: profile.id
        )
        notification.deliveryDate = resetDate
        legacyCenter.scheduleNotification(notification)
    }

    private func makeLegacyNotification(
        identifier: String,
        title: String,
        body: String,
        profileID: UUID? = nil
    ) -> NSUserNotification {
        let notification = NSUserNotification()
        notification.identifier = identifier
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        if let profileID {
            notification.userInfo = ["profileID": profileID.uuidString]
        }
        return notification
    }

    private func removeLegacyNotifications(withPrefix prefix: String) {
        legacyCenter.scheduledNotifications
            .filter { $0.identifier?.hasPrefix(prefix) == true }
            .forEach { legacyCenter.removeScheduledNotification($0) }
        legacyCenter.deliveredNotifications
            .filter { $0.identifier?.hasPrefix(prefix) == true }
            .forEach { legacyCenter.removeDeliveredNotification($0) }
    }

    private func remember(_ identifier: String, in seen: inout Set<String>) {
        seen.insert(identifier)
        if seen.count > 200 {
            seen = Set(seen.sorted().suffix(200))
        }
        defaults.set(Array(seen), forKey: seenAlertIDsKey)
    }

    private func shouldUseCompatibilityMode(for error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "UNErrorDomain" && error.code == 1
    }

    private var shouldPreferCompatibilityMode: Bool {
        defaults.bool(forKey: compatibilityModeKey) || !hasSigningTeamIdentifier
    }

    private var hasSigningTeamIdentifier: Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String]
                as? String else {
            return false
        }
        return !teamIdentifier.isEmpty
    }

    private func profilePrefix(_ id: UUID) -> String {
        "quota-\(id.uuidString)-"
    }

    private func windowLabel(_ window: RateWindow?) -> String {
        guard let minutes = window?.durationMinutes else { return "当前" }
        switch minutes {
        case 300: return "5 小时"
        case 1_440: return "1 天"
        case 10_080: return "1 周"
        default:
            if minutes >= 1_440, minutes % 1_440 == 0 {
                return "\(minutes / 1_440) 天"
            }
            if minutes >= 60, minutes % 60 == 0 {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
        }
    }

    private func resetSuffix(_ date: Date?) -> String {
        guard let date else { return "。" }
        let countdown = QuotaTimeFormatter.countdown(until: date)
        return countdown == "即将重置"
            ? "，即将重置。"
            : "，预计 \(countdown)后重置。"
    }
}
