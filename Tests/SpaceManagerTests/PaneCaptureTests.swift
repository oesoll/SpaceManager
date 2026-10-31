import AppKit
import SwiftUI
import XCTest
@testable import GhosttyTerminal
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
        if env["SM_CAPTURE_SCENE"] == "layout" || env["SM_CAPTURE_SCENE"] == "tabswitch" {
            try captureLayout(appState: appState, workspace: flatWorkspace, appearance: appearance, home: home,
                              measureTabs: env["SM_CAPTURE_SCENE"] == "tabswitch")
            return
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

    /// 세션 층의 배치 데이터를 그대로 그린다: 탭 둘, main은 왼쪽 하나와 오른쪽 위아래 둘(n-ary 트리).
    /// 오른쪽 아래는 아직 tmux에 남아 쉬는 에이전트라 "sm으로 옮기기"가 켜져 있다.
    @MainActor
    private func captureLayout(appState: AppState, workspace: Workspace, appearance: String, home: URL,
                               measureTabs: Bool = false) throws {
        let host = PeerDirectory.shared.localHostName
        let folder = home.appendingPathComponent(".smux/state/sm/workspaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {"schema": 1, "workspace": "\(workspace.effectiveTmuxSessionName)", "host": "\(host)", "cwd": "\(workspace.rootPath)",
         "version": 3, "active_tab": "t-main",
         "tabs": [
          {"id": "t-main", "name": "main", "focus": "p-a", "zoom": null,
           "root": {"dir": "row", "children": [{"pane": "p-a", "size": 0.55},
                    {"dir": "col", "size": 0.45, "children": [{"pane": "p-b", "size": 0.5}, {"pane": "p-c", "size": 0.5}]}]}},
          {"id": "t-eng", "name": "engine", "focus": "p-d", "zoom": null,
           "root": {"dir": "row", "children": [{"pane": "p-d", "size": 0.34}, {"pane": "p-e", "size": 0.33}, {"pane": "p-f", "size": 0.33}]}}
         ],
         "panes": {"p-a": {"session": "flat-frontend", "shell": false}, "p-b": {"session": "flat-qa", "shell": false},
                   "p-c": {"session": "flat-rev", "shell": false, "tmux_pane": "%173"},
                   "p-d": {"session": "flat-engine", "shell": false}, "p-e": {"session": "flat-sol", "shell": false},
                   "p-f": {"session": null, "shell": true}}}
        """
        try json.write(to: folder.appendingPathComponent("flat.json"), atomically: true, encoding: .utf8)

        // 세션 층 없이 찍는다: 패널마다 셸을 띄우고 에이전트 화면은 텍스트로 흉내 낸다.
        appState.layoutTerminals.makeSession = { paneID, pane, _, workspace in
            TerminalSession(kind: .shell, name: pane?.session ?? "zsh", workingDirectory: workspace.rootPath)
        }
        let now = Date()
        func row(_ name: String, _ state: PeerState, since: Date, reason: String? = nil) -> PeerAgent {
            // flat-rev만 아직 tmux 칸에 있다(target이 %NN). 나머지는 sm 세션이다.
            PeerAgent(id: "claude:" + name, name: name, host: host, target: name == "flat-rev" ? "%173" : "hold:" + name,
                      state: state, reason: reason, since: since)
        }
        PeerDirectory.shared.apply(PeerListing(peers: [
            row("flat-frontend", .working, since: now), row("flat-qa", .blocked, since: now.addingTimeInterval(-185), reason: "permission"),
            row("flat-rev", .idle, since: now.addingTimeInterval(-600)), row("flat-engine", .working, since: now),
        ]), now: now)

        let window = try openWindow(CaptureLayout(appState: appState), dark: appearance == "dark")
        defer { window.orderOut(nil) }
        LayoutDirectory.shared.reloadLocal()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let layout = try XCTUnwrap(appState.selectedLayout, "layout file was not picked up")
        let screens = home.appendingPathComponent("screens")
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        let texts = [
            "p-a": "\u{1b}[1m⏺\u{1b}[0m Update(src/components/PriceRow.tsx)\n  ⎿  Updated with 3 additions and 1 removal\n\n\u{1b}[38;5;210m✻\u{1b}[0m Running tests… \u{1b}[2m(38s · esc to interrupt)\u{1b}[0m\n",
            "p-b": "\u{1b}[1m⏺\u{1b}[0m 결제 흐름 E2E를 돌려 보겠습니다.\n\n Bash command\n   pnpm playwright test checkout.spec.ts\n\n Do you want to proceed?\n \u{1b}[38;5;210m❯ 1. Yes\u{1b}[0m\n   2. No\n",
            "p-c": "\u{1b}[1m⏺\u{1b}[0m 리뷰를 마쳤습니다. 반올림이 두 군데에서 다릅니다.\n\n\u{1b}[2m>\u{1b}[0m\n",
        ]
        for (pane, text) in texts {
            let file = screens.appendingPathComponent(pane + ".txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let terminal = appState.layoutTerminals.session(for: pane, in: layout, workspace: workspace).terminalView
            terminal?.sendText("clear; cat '\(file.path)'; sleep 600")
            terminal?.pressReturn()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        let image = try capture(window)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png.write(to: out.appendingPathComponent("layout-\(appearance).png"))
        if measureTabs { try measureTabSwitches(appState: appState, window: window, out: out) }
        if ProcessInfo.processInfo.environment["SM_CAPTURE_SPLIT"] == "1" {
            try measureSplitMotion(appState: appState, layout: layout, workspace: workspace, window: window, out: out)
        }
        for session in appState.layoutTerminals.all { session.cleanup(force: true) }
    }

    /// ⌘D(고르는 상자 자리 열기)와 취소: 카드가 몇 장면에 걸쳐 움직이는지, 메인 스레드가 프레임을 놓치는지,
    /// 움직이는 동안 왼쪽 터미널이 크기를 몇 번 받는지 잰다(받을 때마다 에이전트가 다시 그린다).
    @MainActor
    private func measureSplitMotion(appState: AppState, layout: WorkspaceLayout, workspace: Workspace,
                                    window: NSWindow, out: URL) throws {
        let left = try XCTUnwrap(appState.layoutTerminals.session(for: "p-a", in: layout, workspace: workspace).terminalView)
        // 왼쪽 패널 오른쪽 끝(나누면 왼쪽으로 물러난다)이 지나는 가는 띠.
        let watch = WindowProbe.screenRect(CGRect(x: 380, y: 200, width: 400, height: 6), in: window)
        for (label, action) in [("open", { appState.beginLayoutSplit(.horizontal, in: layout) }),
                                ("cancel", { appState.cancelLayoutSplit() })] as [(String, () -> Void)] {
            let before = left.sizeChanges
            var report: [String: Any]?
            FrameProbe.run(window: window, seconds: 1.2, action: action, watch: watch) { report = $0 }
            // 움직이는 도중(동작 0.3초 뒤에 일어나므로 0.42초 지점 = 움직임 시작 0.12초 뒤) 한 장.
            RunLoop.main.run(until: Date().addingTimeInterval(0.42))
            if let mid = try? capture(window) {
                try? NSBitmapImageRep(cgImage: mid).representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent("split-\(label)-mid.png"))
            }
            let deadline = Date().addingTimeInterval(10)
            while report == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let row = try XCTUnwrap(report)
            // 움직임이 끝난 뒤의 모습(열기: 고르는 상자 자리가 생겼는가).
            let settled = try capture(window)
            try XCTUnwrap(NSBitmapImageRep(cgImage: settled).representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("split-\(label).png"))
            print("split", label, "missed", row["missed"] ?? "-", "max", row["max"] ?? "-", "visible", row["visible_after"] ?? "-",
                  "settled", row["settled_after"] ?? "-", "frames", row["distinct_frames"] ?? "-",
                  "terminal resized", left.sizeChanges - before, "times")
        }
    }

    /// 탭 전환을 사람이 ⌘1·⌘2를 누르는 길로 여러 번 하고, 메인 스레드가 놓친 프레임과 화면이 바뀌고
    /// 멈춘 시각을 잰다(`sm perf --do`와 같은 측정). 결과는 `.build/window-capture/tabswitch.json`.
    @MainActor
    private func measureTabSwitches(appState: AppState, window: NSWindow, out: URL) throws {
        // main 탭에서 왼쪽 패널과 오른쪽 위 패널 사이 틈이 지나는 자리. engine 탭에서는 가운데 패널 안이다.
        let watch = WindowProbe.screenRect(CGRect(x: 740, y: 150, width: 60, height: 40), in: window)
        var rows: [[String: Any]] = []
        for index in 0..<8 {
            let target = index % 2 == 0 ? 1 : 0
            var report: [String: Any]?
            FrameProbe.run(window: window, seconds: 1.0, action: { appState.selectTab(at: target) }, watch: watch) {
                report = $0
            }
            let deadline = Date().addingTimeInterval(10)
            while report == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            var row = try XCTUnwrap(report)
            row["to"] = target == 1 ? "engine" : "main"
            row["visit"] = index < 2 ? "first" : "again"
            row.removeValue(forKey: "steps")
            rows.append(row)
            print("tabswitch", index, row["to"]!, "action_ms", row["action_ms"] ?? "-", "missed", row["missed"] ?? "-",
                  "max", row["max"] ?? "-", "visible", row["visible_after"] ?? "-", "settled", row["settled_after"] ?? "-",
                  "frames", row["distinct_frames"] ?? "-")
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("tabswitch.json"))

        // 다시 오가는 전환 한 번: 도중(0.09초)과 끝난 뒤를 한 장씩 남긴다(tabswitch-mid.png, tabswitch-end.png).
        let target = appState.selectedLayout.flatMap { layout in appState.displayedTab(of: layout).map { layout.tabs.firstIndex(of: $0) } } ?? 0
        appState.selectTab(at: target == 0 ? 1 : 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.09))
        if let mid = try? capture(window) {
            try NSBitmapImageRep(cgImage: mid).representation(using: .png, properties: [:])?
                .write(to: out.appendingPathComponent("tabswitch-mid.png"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let end = try? capture(window) {
            try NSBitmapImageRep(cgImage: end).representation(using: .png, properties: [:])?
                .write(to: out.appendingPathComponent("tabswitch-end.png"))
        }
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
