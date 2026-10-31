import AppKit
import SwiftUI
import XCTest
@testable import SpaceManager

/// 패널 분할과 에이전트 상태를 실제 창으로 찍는다. SEOL이 화면을 판정하는 데 쓴다.
/// `WindowCaptureTests`와 같은 격리(`SM_CAPTURE=1`, 격리 홈, 격리 `TMUX_TMPDIR`)에서만 돈다.
/// 패널은 진짜 셸(libghostty 표면)이고, 에이전트 화면은 그 셸에서 텍스트 파일을 찍어 흉내 낸다.
/// 상태는 가짜 peer 행이다.
/// 결과는 `.build/window-capture/panes-<dark|light>.png`.
final class PaneCaptureTests: XCTestCase {
    @MainActor
    func testCaptureSplitTabWithAgentStates() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        guard home.standardizedFileURL != realHome.standardizedFileURL,
              let tmuxDir = env["TMUX_TMPDIR"], !tmuxDir.hasPrefix("/tmp") else {
            throw XCTSkip("run through scripts/test-isolated.sh with an isolated TMUX_TMPDIR")
        }
        let appearance = env["SM_CAPTURE_CASE"] ?? "dark"

        let storage = home.appendingPathComponent(".space-manager")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var workspaces: [Workspace] = []
        for (name, color) in [("flat", "pink"), ("인체안내서", nil), ("harness", "teal"), ("picturous", "yellow")] as [(String, String?)] {
            let dir = home.appendingPathComponent("work/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var workspace = Workspace(rootPath: dir.path)
            workspace.folderColor = color
            workspaces.append(workspace)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(workspaces).write(to: storage.appendingPathComponent("workspaces.json"))
        UserDefaults.standard.set(appearance, forKey: "preferredAppearance")

        let appState = AppState(windowKind: .workspace)
        let flat = try XCTUnwrap(appState.workspaces.first { $0.name == "flat" })
        appState.selectWorkspace(flat)
        appState.addShellTab()
        let tab = try XCTUnwrap(appState.selectedSession)
        tab.name = "main"
        let flatWorkspace = try XCTUnwrap(appState.selectedWorkspace)
        func shell(_ id: UUID) -> TerminalSession {
            TerminalSession(id: id, kind: .shell, name: "zsh", workingDirectory: flatWorkspace.rootPath)
        }
        if env["SM_CAPTURE_SCENE"] == "picker" {
            try capturePicker(appState: appState, tab: tab, shell: shell, appearance: appearance, home: home)
            return
        }
        let built = appState.panes.ensureGroup(for: tab)
        built.split(.horizontal, make: shell)
        built.split(.vertical, make: shell)
        let group = try XCTUnwrap(appState.selectedPaneGroup)
        let ids = group.paneIDs
        XCTAssertEqual(ids.count, 3)

        // 가짜 peer 행: 왼쪽은 일하는 중, 오른쪽 위는 권한을 기다림, 오른쪽 아래는 끝났는데 아직 안 봄.
        let directory = PeerDirectory.shared
        let local = directory.localHostName
        let t0 = Date()
        func row(_ name: String, pane: UUID, _ state: PeerState, since: Date, reason: String? = nil) -> PeerAgent {
            PeerAgent(id: "claude:" + name, name: name, host: local, target: "sm:" + pane.uuidString,
                      state: state, reason: reason, since: since)
        }
        let tmuxBlocked = PeerAgent(id: "claude:inche-video", name: "inche-video", host: local, target: "%9",
                                    state: .blocked, reason: "question", since: t0.addingTimeInterval(-420),
                                    group: workspaces[1].effectiveTmuxSessionName)
        let tmuxWorking = PeerAgent(id: "claude:harness-scout", name: "harness-scout", host: local, target: "%5",
                                    state: .working, since: t0, group: workspaces[2].effectiveTmuxSessionName)
        directory.apply(PeerListing(peers: [
            row("frontend", pane: ids[0], .working, since: t0.addingTimeInterval(-40)),
            row("qa", pane: ids[1], .blocked, since: t0.addingTimeInterval(-185), reason: "permission"),
            row("rev", pane: ids[2], .working, since: t0.addingTimeInterval(-900)),
            tmuxBlocked, tmuxWorking,
        ]), now: t0)
        directory.apply(PeerListing(peers: [
            row("frontend", pane: ids[0], .working, since: t0.addingTimeInterval(-40)),
            row("qa", pane: ids[1], .blocked, since: t0.addingTimeInterval(-185), reason: "permission"),
            row("rev", pane: ids[2], .idle, since: t0.addingTimeInterval(1), reason: "turn-ended"),
            tmuxBlocked, tmuxWorking,
        ]), now: t0.addingTimeInterval(2))
        group.focus(ids[0])

        // 셸에서 찍을 에이전트 화면.
        let screens = [
            """
            \u{1b}[1m⏺\u{1b}[0m Read(src/app/checkout/page.tsx)
              ⎿  Read 214 lines

            \u{1b}[1m⏺\u{1b}[0m Update(src/components/PriceRow.tsx)
              ⎿  Updated src/components/PriceRow.tsx with 3 additions and 1 removal
                  41  -  const total = Math.round(price * qty)
                  41  +  const total = roundKRW(price * qty)

            \u{1b}[1m⏺\u{1b}[0m 반올림을 한 함수로 모았습니다. 장바구니 합계와 결제 요약이
              같은 값을 쓰는지 테스트로 확인하겠습니다.

            \u{1b}[38;5;210m✻\u{1b}[0m Running tests… \u{1b}[2m(38s · esc to interrupt)\u{1b}[0m
            """,
            """
            \u{1b}[1m⏺\u{1b}[0m 결제 흐름 E2E를 돌려 보겠습니다.

            ╭───────────────────────────────────────────╮
            │ \u{1b}[1mBash command\u{1b}[0m                              │
            │                                           │
            │   pnpm playwright test checkout.spec.ts   │
            │                                           │
            │ Do you want to proceed?                   │
            │ \u{1b}[38;5;210m❯ 1. Yes\u{1b}[0m                                  │
            │   2. Yes, and don't ask again             │
            │   3. No, and tell Claude what to do       │
            ╰───────────────────────────────────────────╯
            """,
            """
            \u{1b}[1m⏺\u{1b}[0m 리뷰를 마쳤습니다. 결제 금액 반올림이 두 군데에서 다릅니다.
              - PriceRow는 Math.round, OrderSummary는 Math.floor
              - 1,274원짜리 상품 3개에서 1원이 어긋납니다

            \u{1b}[2m>\u{1b}[0m
            """,
        ]
        let screenDir = home.appendingPathComponent("screens")
        try FileManager.default.createDirectory(at: screenDir, withIntermediateDirectories: true)
        for (index, text) in screens.enumerated() {
            try text.write(to: screenDir.appendingPathComponent("\(index).txt"), atomically: true, encoding: .utf8)
        }

        let root = CaptureLayout(appState: appState)
        let window = try openWindow(root, dark: appearance == "dark")
        defer { window.orderOut(nil) }
        for (index, id) in ids.enumerated() {
            let file = screenDir.appendingPathComponent("\(index).txt").path
            let terminal = group.session(for: id)?.terminalView
            terminal?.sendText("clear; cat '\(file)'; sleep 600")
            terminal?.pressReturn()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let image = try capture(window)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("panes-\(appearance).png"))
        for id in ids { group.session(for: id)?.cleanup(force: true) }
    }

    /// 고르는 상자 시안: 왼쪽은 일하는 에이전트, 오른쪽은 ⌘D로 막 생긴 자리와 그 안의 상자.
    @MainActor
    private func capturePicker(appState: AppState, tab: TerminalSession, shell: (UUID) -> TerminalSession,
                               appearance: String, home: URL) throws {
        let group = appState.panes.ensureGroup(for: tab)
        appState.splitPane(.horizontal)
        let pickerID = try XCTUnwrap(group.picking.first)
        let context = try XCTUnwrap(group.pickerContexts[pickerID])
        // 상자는 모델·세션 목록을 뒤에서 읽는다. 그 결과가 아래 예시를 덮지 않게 먼저 끝나기를 기다린다.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let now = Date()
        context.claudeModels = [
            AgentModelChoice(id: "claude-opus-5-5", name: "Opus 5.5", efforts: [.low, .medium, .high, .xhigh, .max], defaultEffort: .high),
            AgentModelChoice(id: "claude-sonnet-5-5", name: "Sonnet 5.5", efforts: [.low, .medium, .high], defaultEffort: .high),
        ]
        context.backgroundSessions = [
            AgentPickerSession(name: "flat-qa", engine: .claude, status: .running, lastActive: now, attention: .blocked),
            AgentPickerSession(name: "flat-engine", engine: .codex, status: .running, lastActive: now, attention: .working),
            AgentPickerSession(name: "flat-rev", engine: .claude, status: .ended, lastActive: now.addingTimeInterval(-2400)),
        ]
        UserDefaults.standard.removeObject(forKey: "agentPicker.last")
        let directory = PeerDirectory.shared
        directory.apply(PeerListing(peers: [
            PeerAgent(id: "claude:frontend", name: "frontend", host: directory.localHostName,
                      target: "sm:" + tab.id.uuidString, state: .working, since: now),
        ]), now: now)

        let screens = home.appendingPathComponent("screens")
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        try """
        \u{1b}[1m⏺\u{1b}[0m Update(src/components/PriceRow.tsx)
          ⎿  Updated src/components/PriceRow.tsx with 3 additions and 1 removal

        \u{1b}[1m⏺\u{1b}[0m 반올림을 한 함수로 모았습니다. 장바구니 합계와 결제 요약이
          같은 값을 쓰는지 테스트로 확인하겠습니다.

        \u{1b}[38;5;210m✻\u{1b}[0m Running tests… \u{1b}[2m(38s · esc to interrupt)\u{1b}[0m
        """.write(to: screens.appendingPathComponent("left.txt"), atomically: true, encoding: .utf8)

        let window = try openWindow(CaptureLayout(appState: appState), dark: appearance == "dark")
        defer { window.orderOut(nil) }
        let left = tab.terminalView
        left?.sendText("clear; cat '\(screens.appendingPathComponent("left.txt").path)'; sleep 600")
        left?.pressReturn()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let image = try capture(window)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("picker-\(appearance).png"))
        tab.cleanup(force: true)
    }

    @MainActor
    private func openWindow(_ root: some View, dark: Bool) throws -> NSWindow {
        let size = NSSize(width: 1240, height: 780)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        return window
    }

    @MainActor
    private func capture(_ window: NSWindow) throws -> CGImage {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        let createImage = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CGWindowListCreateImage")), to: CreateImage.self)
        return try XCTUnwrap(createImage(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue())
    }
}

/// ContentView의 작업 창 배치와 같다(단색 바탕, 사이드바 카드 184, 터미널 카드, 8 간격, 12 라운딩).
private struct CaptureLayout: View {
    @ObservedObject var appState: AppState
    @StateObject private var terminalLayout = TerminalLayoutTransition()
    @State private var compact = false

    var body: some View {
        HStack(spacing: 8) {
            SidebarView(isCompact: $compact)
                .frame(width: Sidebar.workspaceWidth)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(rim)
            TerminalAreaView()
        }
        .padding(8)
        .background(Color(Chrome.canvas))
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(appState)
        .environmentObject(terminalLayout)
        .preferredColorScheme(appState.preferredAppearance == "light" ? .light : .dark)
    }

    private var rim: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(Chrome.hairline), lineWidth: 1)
    }
}
