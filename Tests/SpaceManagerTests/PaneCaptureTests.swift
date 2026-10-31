import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SpaceManager

/// 패널 분할과 에이전트 상태를 실제 창으로 찍는다. SEOL이 화면을 판정하는 데 쓴다.
/// `WindowCaptureTests`와 같은 격리(`SM_CAPTURE=1`, 격리 홈, 격리 `TMUX_TMPDIR`)에서만 돈다.
/// 패널은 진짜 셸이고, 에이전트 화면은 그 셸에서 텍스트 파일을 찍어 흉내 낸다. 상태는 가짜 peer 행이다.
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
        appState.splitPane(.horizontal)
        appState.splitPane(.vertical)
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
            group.session(for: id)?.terminalView?.onUserInput?(Data("clear; cat '\(file)'; sleep 600\r".utf8))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let image = try composite(capture(window), webViewsOf: window)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("panes-\(appearance).png"))
        for id in ids { group.session(for: id)?.cleanup(force: true) }
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
        // 테스트 창은 WebKit이 '가려짐'으로 보고 xterm이 그리지 않는다. 가림 감지를 끄고,
        // 창 캡처에 잡히지 않는 WebGL 대신 같은 테마로 칠하는 DOM 렌더러로 내린다.
        for web in webViews(in: window.contentView) {
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: selector) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: selector), to: Setter.self)(web, selector, false)
            }
            web.evaluateJavaScript("""
                try { term._addonManager._addons.forEach(a => { if (a.instance.constructor.name.includes('Webgl')) a.instance.dispose(); });
                      term.refresh(0, term.rows - 1); } catch (e) {}
                """, completionHandler: nil)
        }
        // 가림 감지를 끈 뒤에도 이미 hidden이 된 페이지는 창 상태가 바뀔 때까지 그대로다.
        window.orderOut(nil)
        window.orderFrontRegardless()
        window.setContentSize(NSSize(width: size.width, height: size.height - 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        return window
    }

    @MainActor
    private func capture(_ window: NSWindow) throws -> CGImage {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        let createImage = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CGWindowListCreateImage")), to: CreateImage.self)
        return try XCTUnwrap(createImage(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue())
    }

    /// 창 캡처에는 WKWebView 내용이 비어 나온다. 터미널마다 WebKit 스냅숏을 떠서 제자리에 덧그린다.
    @MainActor
    private func composite(_ base: CGImage, webViewsOf window: NSWindow) throws -> CGImage {
        let content = try XCTUnwrap(window.contentView)
        let scale = CGFloat(base.width) / content.bounds.width
        let context = try XCTUnwrap(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for web in webViews(in: content) where web.window != nil && !web.isHidden && web.alphaValue > 0 {
            var shot: NSImage?
            web.takeSnapshot(with: nil) { image, _ in shot = image }
            let deadline = Date().addingTimeInterval(5)
            while shot == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let cg = shot?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            // 창 좌표(아래가 0)를 그대로 CG 좌표로 쓴다. 보이는 부분만 — 부모가 자른 곳은 자른다.
            var rect = web.convert(web.bounds, to: nil)
            var clip = rect
            var ancestor = web.superview
            while let view = ancestor {
                clip = clip.intersection(view.convert(view.bounds, to: nil))
                ancestor = view.superview
            }
            rect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            clip = CGRect(x: clip.minX * scale, y: clip.minY * scale, width: clip.width * scale, height: clip.height * scale)
            context.saveGState()
            context.clip(to: clip)
            context.draw(cg, in: rect)
            context.restoreGState()
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
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
