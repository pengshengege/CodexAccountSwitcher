import SwiftUI
import SwitcherCore

private enum AppPage: String, CaseIterable, Identifiable {
    case accounts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号管理"
        case .settings: return "系统设置"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: AccountManager
    @State private var selectedPage: AppPage = .accounts

    var body: some View {
        NavigationSplitView {
            SidebarView(manager: manager, selectedPage: $selectedPage)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
        } detail: {
            switch selectedPage {
            case .accounts:
                AccountManagementView(manager: manager)
            case .settings:
                SettingsView(manager: manager)
            }
        }
        .tint(Color(red: 0.12, green: 0.39, blue: 0.94))
        .sheet(
            isPresented: Binding(
                get: { manager.isolatedLoginState != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    if manager.isolatedLoginState?.isWorking == true {
                        manager.cancelIsolatedLogin()
                    } else {
                        manager.dismissIsolatedLogin()
                    }
                }
            )
        ) {
            IsolatedLoginSheet(manager: manager)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var manager: AccountManager
    @Binding var selectedPage: AppPage

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CODEX SWITCHER")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(2)
                Text("本地多账号工作台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            List(AppPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .tag(page)
                    .padding(.vertical, 5)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            CurrentAccountPanel(manager: manager)
                .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }
}

private struct CurrentAccountPanel: View {
    @ObservedObject var manager: AccountManager

    private var activeProfile: AccountProfile? {
        manager.accounts.first { $0.id == manager.activeProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(activeProfile == nil ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
            }

            Text(activeProfile?.displayName ?? "尚未归档")
                .font(.headline)
                .lineLimit(1)

            Text(manager.currentIdentity?.email ?? "未检测到登录身份")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            HStack {
                Label(
                    manager.appController.isRunning ? "Codex 运行中" : "Codex 未运行",
                    systemImage: manager.appController.isRunning
                        ? "bolt.fill"
                        : "moon.zzz.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    manager.appController.isRunning ? Color.green : Color.secondary
                )
                Spacer()
                Button {
                    manager.openCodex()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("打开 Codex")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct AccountManagementView: View {
    @ObservedObject var manager: AccountManager

    private let columns = [
        GridItem(.adaptive(minimum: 370, maximum: 560), spacing: 18)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(manager: manager)
            Divider()

            if manager.pendingRestart {
                RestartBanner(manager: manager)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
            }

            if manager.accounts.isEmpty {
                EmptyAccountsView(manager: manager)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(manager.accounts) { profile in
                            AccountCard(
                                profile: profile,
                                isActive: manager.activeProfileID == profile.id,
                                isChecking: manager.checkingIDs.contains(profile.id),
                                manager: manager
                            )
                        }
                    }
                    .padding(22)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HeaderBar: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("账号管理")
                    .font(.system(size: 24, weight: .bold))
                Text("独立添加账号，不再退出当前登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                manager.openCodex()
            } label: {
                Label("打开 Codex", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)

            Button {
                manager.beginIsolatedLogin()
            } label: {
                Label("添加新账号", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isolatedLoginState?.isWorking == true)

            Menu {
                Button("导入当前已登录账号") {
                    manager.importCurrent()
                }
                .disabled(manager.isImporting)
                Text("仅用于归档当前账号，不要先退出 Codex")
            } label: {
                if manager.isImporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("更多导入方式")

            Button {
                manager.refreshAll()
            } label: {
                if manager.isRefreshingAll {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(manager.isRefreshingAll || manager.accounts.isEmpty)
            .help("检测全部账号")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }
}

private struct RestartBanner: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(Color.orange)
            Text("账号已经写入，重启 Codex 后生效。")
                .font(.subheadline)
            Spacer()
            Button("立即重启") {
                manager.restartCodex()
            }
            .buttonStyle(.borderedProminent)
            Button {
                manager.pendingRestart = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct EmptyAccountsView: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("还没有账号档案")
                .font(.title2.bold())
            Text("已在 Codex 登录时，可先导入当前账号。\n添加其他账号请走独立登录，不需要退出当前账号。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("导入当前已登录账号") {
                    manager.importCurrent()
                }
                .buttonStyle(.bordered)
                Button("添加其他账号") {
                    manager.beginIsolatedLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
