import SwiftUI
import AppKit

enum AppTermination {
    static var isTerminating = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `sm` CLI 제어 소켓. 실패해도 앱은 정상 동작한다 — CLI만 못 붙는다.
        let server = ControlServer(path: ControlCommands.socketPath) { request, respond in
            ControlCommands.handle(request, completion: respond)
        }
        do { try server.start(); controlServer = server } catch {
            NSLog("control server unavailable: \(error)")
        }
        // 화면 노치. Fine이 아직 노치를 가졌으면 넘겨 주기만 하고, 걷어 냈으면 이어받는다(NotchOwner).
        MainActor.assumeIsolated {
            NotchOwner.shared.start()
            // 메뉴 막대의 sm 아이콘: 누르면 창 전부 숨기기, 다시 누르면 보이기.
            StatusBarToggle.shared.install()
        }
        // 라이트/다크는 창별(AppState.preferredAppearance → NSWindow.appearance) —
        // 전역 NSApp.appearance는 건드리지 않는다
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 메뉴 막대 아이콘으로 숨긴 채 Dock을 누르면, 숨긴 창을 그대로 되돌린다.
        let restored = MainActor.assumeIsolated { () -> Bool in
            guard StatusBarToggle.shared.isHiding else { return false }
            StatusBarToggle.shared.reveal()
            return true
        }
        if restored { return true }
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controlServer?.stop()
        WorkspaceWindowRegistry.shared.persistWindowPresentations()
        // 종료 시 AppState.deinit이 창 상태를 지우지 않도록 표시
        AppTermination.isTerminating = true
        return .terminateNow
    }
}

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 창·패널이 하나라도 뜨기 전에: 에이전트 셸에서 띄웠으면 그 세션의 정체를 지운다(InheritedAgentSession).
        let cleared = InheritedAgentSession.clear()
        if !cleared.isEmpty { NSLog("cleared inherited agent session variables: %@", cleared.joined(separator: " ")) }
    }

    var body: some Scene {
        WindowGroup(id: "main", for: UUID.self) { $windowStateId in
            ContentView(windowStateId: $windowStateId)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands()
        }

        WindowGroup(id: "quick", for: UUID.self) { $windowStateId in
            ContentView(windowKind: .quick, windowStateId: $windowStateId)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// 메뉴 커맨드 — FocusedObject로 "활성 창"의 AppState에 바인딩된다
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    private var isWorkspaceWindow: Bool { appState?.windowKind == .workspace }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Quick Window") {
                openWindow(id: "quick", value: UUID())
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("New Workspace") {
                appState?.showNewWorkspaceSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appState == nil || appState?.windowKind == .quick)

            Button(appState?.windowKind == .quick ? "New Quick Conversation" : "New Terminal Tab") {
                if let appState, let layout = appState.selectedLayout {
                    appState.beginLayoutNewTab(in: layout)
                } else {
                    appState?.addDefaultTab()
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState == nil)

            Button("New tmux Tab") {
                appState?.addTmuxTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(appState == nil || appState?.windowKind == .quick || !TmuxBootstrap.isTmuxAvailable)
        }

        CommandMenu("Tabs") {
            Button("Previous Tab") {
                appState?.stepTab(forward: false)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(appState == nil)

            Button("Next Tab") {
                appState?.stepTab(forward: true)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(appState == nil)

            ForEach(1...9, id: \.self) { number in
                Button("탭 \(number)") { appState?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(appState == nil)
            }

            Divider()

            // tmux의 prefix 키가 하던 일. 터미널이 키를 먼저 먹지 않도록 메뉴 단축키로 둔다.
            Button("패널 오른쪽으로 나누기") {
                appState?.splitPane(.horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!isWorkspaceWindow)

            Button("패널 아래로 나누기") {
                appState?.splitPane(.vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!isWorkspaceWindow)

            Button("다음 패널") {
                appState?.cyclePane(forward: true)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(appState?.hasMultiplePanes != true)

            Button("이전 패널") {
                appState?.cyclePane(forward: false)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(appState?.hasMultiplePanes != true)

            Button("패널 확대") {
                appState?.toggleZoomPane()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(appState?.hasMultiplePanes != true)

            Button("기다리는 패널로") {
                appState?.focusNextWaitingPane()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!isWorkspaceWindow)
        }
    }
}

    /// 앱 시작 시 아직 macOS scene restoration이 만들지 않은 상태만 정확한 ID로 연다.
enum WindowRestorer {
    private static var didRun = false

    @MainActor
    static func openRemainingWindowsIfNeeded(_ openWindow: OpenWindowAction) {
        guard !didRun else { return }
        didRun = true
        // 시스템 상태 복원이 창을 이미 띄웠을 수 있으므로 잠시 뒤 부족분 계산
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let storage = WorkspaceStorage.shared
            for kind in WindowKind.allCases {
                for state in storage.unclaimedWindowStates(for: kind) {
                    openWindow(id: kind.sceneID, value: state.id)
                }
            }
        }
    }
}
