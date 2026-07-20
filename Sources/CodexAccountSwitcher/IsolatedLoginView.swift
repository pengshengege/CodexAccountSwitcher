import SwiftUI

struct IsolatedLoginSheet: View {
    @ObservedObject var manager: AccountManager
    @State private var copiedLink = false

    private var state: IsolatedLoginState {
        manager.isolatedLoginState ?? IsolatedLoginState()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(24)
            Divider()
            content
                .padding(24)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 540)
        .interactiveDismissDisabled(state.isWorking)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("添加新账号")
                    .font(.title2.bold())
                Text("独立登录，不退出当前 Codex 账号")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .starting:
            statusView(
                icon: "lock.shield.fill",
                title: "正在创建独立登录环境…",
                message: "不会读取或覆盖 ~/.codex/auth.json。",
                color: .accentColor,
                showsProgress: true
            )
        case .waitingForAuthorization:
            waitingView
        case .importing:
            statusView(
                icon: "key.fill",
                title: "登录完成，正在安全保存…",
                message: "独立临时目录会在导入后立即删除。",
                color: .accentColor,
                showsProgress: true
            )
        case .completed:
            statusView(
                icon: "checkmark.circle.fill",
                title: "账号已保存",
                message: state.completionMessage ?? "当前 Codex 登录保持不变。",
                color: .green,
                showsProgress: false
            )
        case .failed:
            failedView
        }
    }

    private var waitingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("请在浏览器里登录你要添加的账号")
                .font(.headline)

            Text("这是普通 ChatGPT 浏览器登录，不需要在安全设置中开启“设备代码授权”。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("登录页已在默认浏览器中打开", systemImage: "safari.fill")
                Label("登录目标账号并确认授权", systemImage: "person.crop.circle.badge.checkmark")
                Label("完成后会自动保存，无需复制验证码", systemImage: "key.fill")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color.accentColor.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )

            HStack(spacing: 10) {
                Button {
                    manager.openIsolatedLoginPage()
                } label: {
                    Label("打开登录页", systemImage: "safari.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    manager.copyIsolatedLoginLink()
                    copiedLink = true
                } label: {
                    Label(
                        copiedLink ? "链接已复制" : "复制登录链接",
                        systemImage: copiedLink ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(state.authorizationURL == nil)

            Text("如果默认浏览器正登录着别的账号，可复制链接后粘贴到隐私窗口或目标账号的浏览器个人资料中。不要在 Codex 应用里点“退出登录”。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("等待本机 OAuth 回调；10 分钟后自动超时")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.output.isEmpty {
                DisclosureGroup("登录过程详情") {
                    ScrollView {
                        Text(state.output)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var failedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color.orange)
            Text("没有完成登录")
                .font(.headline)
            Text(state.errorMessage ?? "请检查网络后重试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func statusView(
        icon: String,
        title: String,
        message: String,
        color: Color,
        showsProgress: Bool
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Text("当前登录档始终不会被这个流程修改")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch state.phase {
            case .starting, .waitingForAuthorization:
                Button("取消") {
                    manager.cancelIsolatedLogin()
                }
                .keyboardShortcut(.cancelAction)
            case .importing:
                Text("正在导入…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .completed:
                Button("完成") {
                    manager.dismissIsolatedLogin()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("关闭") {
                    manager.dismissIsolatedLogin()
                }
                Button("重试") {
                    manager.beginIsolatedLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
