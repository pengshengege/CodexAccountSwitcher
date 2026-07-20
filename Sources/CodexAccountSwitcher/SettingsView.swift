import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("系统设置")
                        .font(.system(size: 24, weight: .bold))
                    Text("切换行为和本地存储")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 17)
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    SettingsCard(title: "切换行为", icon: "arrow.triangle.2.circlepath") {
                        Toggle("切换后自动重启 Codex", isOn: $manager.autoRestart)
                        Text("关闭时只替换登录档，你可以确认手头任务结束后再重启 Codex。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "菜单栏与额度提醒", icon: "bell.badge.fill") {
                        Toggle(
                            "启用额度提醒与定时检测",
                            isOn: Binding(
                                get: { manager.quotaNotificationsEnabled },
                                set: { manager.setQuotaNotificationsEnabled($0) }
                            )
                        )

                        HStack {
                            Label(
                                manager.notificationStatusText,
                                systemImage: manager.quotaNotificationsEnabled
                                    ? "checkmark.circle.fill"
                                    : "bell.slash.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                manager.quotaNotificationsEnabled
                                    ? Color.green
                                    : Color.secondary
                            )
                            Spacer()
                            if !manager.notificationUsesCompatibilityMode {
                                Button("系统通知设置") {
                                    manager.openNotificationSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button("测试通知") {
                                manager.sendTestNotification()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if manager.quotaNotificationsEnabled {
                            Divider()
                            HStack {
                                Text("低额度阈值")
                                Spacer()
                                Picker("低额度阈值", selection: $manager.quotaAlertThreshold) {
                                    Text("10%").tag(10.0)
                                    Text("20%").tag(20.0)
                                    Text("30%").tag(30.0)
                                }
                                .labelsHidden()
                                .frame(width: 110)
                            }

                            HStack {
                                Text("自动检测间隔")
                                Spacer()
                                Picker("自动检测间隔", selection: $manager.automaticRefreshMinutes) {
                                    Text("5 分钟").tag(5)
                                    Text("15 分钟").tag(15)
                                    Text("30 分钟").tag(30)
                                    Text("1 小时").tag(60)
                                }
                                .labelsHidden()
                                .frame(width: 110)
                            }
                        }

                        Text("应用会常驻菜单栏；低于阈值时仅提醒一次，并提前安排额度窗口重置通知。定时检测只在应用运行时执行；本地临时签名版本会自动使用兼容提醒。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "安全与隐私", icon: "lock.shield.fill") {
                        Label("完整登录档仅存于当前用户的私密目录", systemImage: "externaldrive.fill.badge.checkmark")
                        Label("私密目录为 0700，登录档文件为 0600", systemImage: "lock.fill")
                        Label("后台检测完全不访问旧版钥匙串", systemImage: "rectangle.badge.xmark")
                        Label("账号列表只保存名称、邮箱和额度摘要", systemImage: "list.bullet.rectangle")
                        Label("状态检测通过本机 Codex app-server 完成", systemImage: "checkmark.seal.fill")
                        Text("旧版本保存在钥匙串的账号，只会在你主动切换时读取一次并迁移；完成后检测和切换都不再访问钥匙串。本工具不会读取浏览器 Cookie，也不会把登录档上传到第三方服务器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "路径", icon: "folder.fill") {
                        PathRow(label: "当前登录档", value: manager.authPath)
                        Divider()
                        PathRow(label: "Codex 后端", value: manager.codexBinaryPath)
                        HStack {
                            Spacer()
                            Button("打开数据目录") {
                                manager.revealDataDirectory()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    SettingsCard(title: "关于", icon: "info.circle.fill") {
                        HStack {
                            Text("Codex Account Switcher")
                            Spacer()
                            Text("v0.2.3")
                                .foregroundStyle(.secondary)
                        }
                        Text("这是一个本地账号档案工具，不隶属于 OpenAI。额度数据以 Codex 客户端实际返回为准。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            Divider()
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.70),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct PathRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
