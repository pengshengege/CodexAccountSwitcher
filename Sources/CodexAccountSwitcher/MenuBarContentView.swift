import AppKit
import SwiftUI
import SwitcherCore

struct MenuBarLabel: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if let remaining = manager.menuBarRemainingPercent {
                Text("\(Int(remaining.rounded()))%")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var iconName: String {
        guard manager.activeProfile != nil else {
            return "person.crop.circle.badge.questionmark"
        }
        if manager.activeProfileNeedsReauthorization {
            return "person.crop.circle.badge.exclamationmark"
        }
        if let remaining = manager.menuBarRemainingPercent,
           remaining <= manager.quotaAlertThreshold {
            return "exclamationmark.circle.fill"
        }
        return "arrow.triangle.2.circlepath.circle.fill"
    }

    private var accessibilityText: String {
        guard let profile = manager.activeProfile else {
            return "Codex 账号切换：没有当前账号"
        }
        if manager.activeProfileNeedsReauthorization {
            return "Codex 当前账号 \(profile.displayName)，需要重新登录"
        }
        if let remaining = manager.menuBarRemainingPercent {
            return "Codex 当前账号 \(profile.displayName)，最低额度剩余 \(Int(remaining.rounded()))%"
        }
        return "Codex 当前账号 \(profile.displayName)"
    }
}

struct MenuBarContentView: View {
    @ObservedObject var manager: AccountManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(14)

            if manager.pendingRestart {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.orange)
                    Text("重启 Codex 后生效")
                        .font(.caption)
                    Spacer()
                    Button("重启") {
                        manager.restartCodex()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            if manager.accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text("还没有账号档案")
                        .font(.headline)
                    Button("导入当前账号") {
                        manager.importCurrent()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.accounts) { profile in
                            MenuBarAccountRow(
                                profile: profile,
                                isActive: manager.activeProfileID == profile.id,
                                isChecking: manager.checkingIDs.contains(profile.id),
                                isSwitching: manager.switchingProfileID == profile.id,
                                manager: manager,
                                onReauthorize: {
                                    openWindow(id: "main")
                                    NSApp.activate(ignoringOtherApps: true)
                                    manager.beginIsolatedLogin()
                                }
                            )
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        manager.refreshAll()
                    } label: {
                        Label("刷新全部", systemImage: "arrow.clockwise")
                    }
                    .disabled(manager.isRefreshingAll)

                    Button {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        manager.beginIsolatedLogin()
                    } label: {
                        Label("添加账号", systemImage: "person.badge.plus")
                    }
                    .disabled(manager.isolatedLoginState?.isWorking == true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("切换后自动重启 Codex", isOn: $manager.autoRestart)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)

                HStack {
                    Button("打开账号管理") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("退出") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, 5)
            }
            .padding(12)
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(manager.activeProfile?.displayName ?? "Codex Switcher")
                    .font(.headline)
                    .lineLimit(1)
                if let remaining = manager.menuBarRemainingPercent {
                    Text("最低额度剩余 \(Int(remaining.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(remaining <= 20 ? Color.orange : Color.secondary)
                } else {
                    Text("点击账号即可快速切换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.isRefreshingAll {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(manager.appController.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .help(manager.appController.isRunning ? "Codex 运行中" : "Codex 未运行")
            }
        }
    }
}

private struct MenuBarAccountRow: View {
    let profile: AccountProfile
    let isActive: Bool
    let isChecking: Bool
    let isSwitching: Bool
    @ObservedObject var manager: AccountManager
    let onReauthorize: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if needsReauthorization {
                    onReauthorize()
                } else {
                    manager.switchTo(profile.id)
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(isActive
                                ? Color.accentColor.opacity(0.16)
                                : Color.primary.opacity(0.06))
                        Text(initial)
                            .font(.caption.bold())
                            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(profile.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(quotaText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(quotaColor)
                            .lineLimit(1)
                    }
                    Spacer()
                    if needsReauthorization {
                        Image(systemName: "person.badge.key.fill")
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    } else if isSwitching {
                        ProgressView()
                            .controlSize(.small)
                    } else if !isActive {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                (isActive && !needsReauthorization)
                    || isSwitching
                    || manager.switchingProfileID != nil
            )

            Button {
                manager.check(profile.id)
            } label: {
                if isChecking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            .help("刷新这个账号")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var initial: String {
        profile.displayName.first.map { String($0).uppercased() } ?? "C"
    }

    private var remaining: Double? {
        guard let quota = profile.quota else { return nil }
        return [quota.primary, quota.secondary]
            .compactMap { $0?.remainingPercent }
            .min()
    }

    private var quotaText: String {
        if needsReauthorization {
            return "需重新登录 · 点击重新授权"
        }
        if let remaining {
            return "最低剩余 \(Int(remaining.rounded()))% · \(profile.planType?.uppercased() ?? "CODEX")"
        }
        switch profile.health {
        case .unchecked: return "尚未检测额度"
        case .available: return "账号可用"
        case .unavailable: return "暂不可用"
        case .expired: return "登录已过期"
        }
    }

    private var quotaColor: Color {
        if needsReauthorization { return .red }
        guard let remaining else {
            return profile.health == .expired ? .red : .secondary
        }
        if remaining <= 20 { return .orange }
        return .secondary
    }

    private var needsReauthorization: Bool {
        if profile.health == .expired { return true }
        let error = profile.lastError?.lowercased() ?? ""
        return error.contains("401")
            || error.contains("unauthorized")
            || error.contains("invalidated oauth token")
            || error.contains("登录令牌已被撤销")
    }
}
