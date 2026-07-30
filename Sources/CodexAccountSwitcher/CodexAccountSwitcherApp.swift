import SwiftUI

@main
struct CodexAccountSwitcherApp: App {
    @StateObject private var manager = AccountManager()

    var body: some Scene {
        WindowGroup("Codex Account Switcher", id: "main") {
            ContentView(manager: manager)
                .frame(minWidth: 980, minHeight: 640)
                .alert(item: $manager.notice) { notice in
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        dismissButton: .default(Text("好"))
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加新账号…") {
                    manager.beginIsolatedLogin()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(manager.isAccountOperationInProgress)
            }
            CommandMenu("账号") {
                Button("从文件导入 Session…") {
                    manager.importSessionFile()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(manager.isAccountOperationInProgress)

                if let activeProfile = manager.activeProfile {
                    Button("导出当前账号 Session…") {
                        manager.exportSession(activeProfile.id)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(manager.isAccountOperationInProgress)
                }

                Divider()

                Button("添加新账号…") {
                    manager.beginIsolatedLogin()
                }
                .disabled(manager.isAccountOperationInProgress)

                Button("导入当前已登录账号") {
                    manager.importCurrent()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(manager.isAccountOperationInProgress)

                Button("检测全部账号") {
                    manager.refreshAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    manager.isAccountOperationInProgress || manager.accounts.isEmpty
                )
            }
        }

        MenuBarExtra {
            MenuBarContentView(manager: manager)
        } label: {
            MenuBarLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}
