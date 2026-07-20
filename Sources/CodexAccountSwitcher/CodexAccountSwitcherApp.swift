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
            }
            CommandMenu("账号") {
                Button("添加新账号…") {
                    manager.beginIsolatedLogin()
                }

                Button("导入当前已登录账号") {
                    manager.importCurrent()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("检测全部账号") {
                    manager.refreshAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
