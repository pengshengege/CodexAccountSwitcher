import SwiftUI
import SwitcherCore

private enum CardConfirmation: Identifiable {
    case switchAccount
    case delete

    var id: Int {
        switch self {
        case .switchAccount: return 1
        case .delete: return 2
        }
    }
}

struct AccountCard: View {
    let profile: AccountProfile
    let isActive: Bool
    let isChecking: Bool
    @ObservedObject var manager: AccountManager

    @State private var confirmation: CardConfirmation?
    @State private var showingRename = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.16),
                                    Color.accentColor.opacity(0.07)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(initials)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(1)
                        if isActive {
                            StatusBadge(text: "当前", color: .blue)
                        }
                        if needsReauthorization {
                            StatusBadge(text: "需重新登录", color: .red)
                        } else {
                            HealthBadge(health: profile.health)
                        }
                    }
                    Text(profile.email ?? accountSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)

                Button {
                    renameDraft = profile.displayName
                    showingRename = true
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 34, height: 30)
                        .background(
                            Color.accentColor.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
                .help("重命名")
            }

            quotaSection

            if let error = userFacingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button {
                    if needsReauthorization {
                        manager.beginIsolatedLogin()
                    } else {
                        confirmation = .switchAccount
                    }
                } label: {
                    Label(
                        needsReauthorization
                            ? "重新授权这个账号"
                            : (isActive ? "当前账号" : "切换到这个账号"),
                        systemImage: needsReauthorization
                            ? "person.badge.key.fill"
                            : (isActive ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled((isActive && !needsReauthorization) || isChecking)

                Button {
                    manager.check(profile.id)
                } label: {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isChecking)
                .help("检测账号和额度")

                Button(role: .destructive) {
                    confirmation = .delete
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("删除档案")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.50) : Color.primary.opacity(0.09),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.045), radius: 12, y: 4)
        .alert(item: $confirmation) { action in
            switch action {
            case .switchAccount:
                return Alert(
                    title: Text("切换到 \(profile.displayName)？"),
                    message: Text(manager.autoRestart
                        ? "登录档将被替换，随后 Codex 会重新启动。"
                        : "登录档将被替换；重启 Codex 后生效。"),
                    primaryButton: .default(Text("切换")) {
                        manager.switchTo(profile.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .delete:
                return Alert(
                    title: Text("删除 \(profile.displayName)？"),
                    message: Text("本机私密存储中的这个登录档会一并删除；当前 Codex 登录不会退出。"),
                    primaryButton: .destructive(Text("删除")) {
                        manager.delete(profile.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .sheet(isPresented: $showingRename) {
            RenameAccountSheet(
                name: $renameDraft,
                onCancel: { showingRename = false },
                onSave: {
                    manager.rename(profile.id, to: renameDraft)
                    showingRename = false
                }
            )
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("额度", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let plan = profile.planType ?? profile.quota?.planType {
                    Text(plan.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }

            if let quota = profile.quota {
                if let primary = quota.primary {
                    QuotaWindowRow(window: primary)
                }
                if let secondary = quota.secondary {
                    QuotaWindowRow(window: secondary)
                }
                if quota.primary == nil && quota.secondary == nil {
                    noQuotaText("当前方案没有返回滚动额度窗口")
                }
            } else {
                noQuotaText(isChecking ? "正在读取额度…" : "点击心电图按钮检测额度")
            }

            Divider()
                .opacity(0.55)

            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                if let date = profile.lastCheckedAt {
                    Text("上次检测 \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("尚未检测")
                }
                Spacer()
                if isChecking {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        )
    }

    private func noQuotaText(_ text: String) -> some View {
        Label(
            text,
            systemImage: isChecking ? "arrow.triangle.2.circlepath" : "chart.bar.xaxis"
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var initials: String {
        let words = profile.displayName.split(separator: " ")
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "C" : value.uppercased()
    }

    private var accountSubtitle: String {
        profile.authMode.lowercased().contains("api") ? "API Key 登录" : "ChatGPT 登录"
    }

    private var needsReauthorization: Bool {
        guard profile.health == .expired || profile.lastError != nil else {
            return false
        }
        if profile.health == .expired { return true }
        let error = profile.lastError?.lowercased() ?? ""
        return error.contains("401")
            || error.contains("unauthorized")
            || error.contains("invalidated oauth token")
            || error.contains("登录令牌已被撤销")
    }

    private var userFacingError: String? {
        guard let error = profile.lastError, !error.isEmpty else { return nil }
        if needsReauthorization {
            return "这个令牌已被退出登录撤销。请点“重新授权这个账号”，不要在 Codex 中退出登录。"
        }
        let normalized = error.lowercased()
        if normalized.contains("钥匙串")
            || normalized.contains("keychain")
            || normalized.contains("-128")
            || normalized.contains("-25308") {
            return "此账号来自旧版本；主动切换一次即可迁移，之后检测和切换都不会再访问钥匙串。"
        }
        if normalized.contains("codex_models_manager")
            || normalized.contains("unexpected status")
            || error.count > 180 {
            return "本次检测未完成，请稍后重试；若持续失败，可重新授权这个账号。"
        }
        return error
    }
}

private struct QuotaWindowRow: View {
    let window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(durationLabel)
                    .font(.subheadline.weight(.semibold))
                Text("额度窗口")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(progressColor)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [progressColor.opacity(0.72), progressColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: proxy.size.width
                                * min(1, max(0, window.remainingPercent / 100))
                        )
                }
            }
            .frame(height: 7)
            .accessibilityLabel("剩余额度")
            .accessibilityValue("\(Int(window.remainingPercent.rounded()))%")

            HStack(spacing: 8) {
                Text("已用 \(Int(window.usedPercent.rounded()))%")
                    .foregroundStyle(.tertiary)
                Spacer()
                if let reset = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Label(
                            resetText(reset, relativeTo: context.date),
                            systemImage: "clock"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("重置时间未知")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(12)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var durationLabel: String {
        guard let minutes = window.durationMinutes else { return "窗口" }
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

    private var progressColor: Color {
        switch window.remainingPercent {
        case 50...: return .green
        case 20..<50: return .orange
        default: return .red
        }
    }

    private func resetText(_ date: Date, relativeTo referenceDate: Date) -> String {
        let countdown = QuotaTimeFormatter.countdown(
            until: date,
            from: referenceDate
        )
        return countdown == "即将重置" ? countdown : "\(countdown)后重置"
    }
}

private struct RenameAccountSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名账号")
                .font(.title2.bold())
            TextField("账号名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.11), in: Capsule())
    }
}

struct HealthBadge: View {
    let health: AccountHealth

    var body: some View {
        StatusBadge(text: label, color: color)
    }

    private var label: String {
        switch health {
        case .unchecked: return "未检测"
        case .available: return "可用"
        case .unavailable: return "暂不可用"
        case .expired: return "登录过期"
        }
    }

    private var color: Color {
        switch health {
        case .unchecked: return .secondary
        case .available: return .green
        case .unavailable: return .orange
        case .expired: return .red
        }
    }
}
