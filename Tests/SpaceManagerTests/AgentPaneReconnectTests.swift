import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 다른 기기의 에이전트 패널이 ssh가 끊긴 뒤(255) 다시 붙는가. 맥을 오래 덮었다 열면 아치 패널이 끊긴 채로
/// 남았다(10/31) — 다시 붙기 규칙이 옛 tmux 탭만 보고 있었다. 실제 ssh는 다른 앱과 공유 연결이라 끊지 않고,
/// 격리된 홈에 가짜 sm-session을 둔다: 처음엔 1초 뒤 255로 끝나고, 그다음부터는 붙어 있는다.
@MainActor
final class AgentPaneReconnectTests: XCTestCase {
    func testRemotePaneReattachesAfterSshDrops() throws {
        try reattaches(host: "arch-elsewhere", firstExit: 255)
    }

    /// 이 맥의 세션 패널도 attach가 끝나면 다시 붙는다. SEOL이 쿼타 때문에 세션을 껐다 되살렸는데 sm 창이
    /// 죽어 있었다(11/01) — attach가 죽은 패널을 다시 띄우지 않았다.
    func testLocalPaneReattachesAfterItsAttachEnds() throws {
        try reattaches(host: PeerDirectory.shared.localHostName, firstExit: 0)
    }

    private func reattaches(host: String, firstExit: Int32) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh")
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("sm-session")
        let count = bin.appendingPathComponent("attach-count")
        try? FileManager.default.removeItem(at: count)
        try """
        #!/bin/sh
        n=$(cat '\(count.path)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(count.path)'
        if [ "$n" -eq 1 ]; then printf 'first\\n'; sleep 1; exit \(firstExit); fi
        printf 'again %s\\n' "$n"; exec sleep 60
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake); try? FileManager.default.removeItem(at: count) }
        func attaches() -> Int { Int(((try? String(contentsOf: count, encoding: .utf8)) ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let session = TerminalSession(kind: .shell, name: "qa", workingDirectory: NSHomeDirectory(),
                                      attachment: .agent(name: "qa", host: host, agent: nil))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView = host
        window.orderFrontRegardless()
        host.show(session.getOrCreateTerminal())
        defer { session.cleanup(force: true); window.close() }

        func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }
        XCTAssertTrue(wait(5) { attaches() >= 1 }, "the pane never attached")
        XCTAssertTrue(wait(5) { session.isReconnecting }, "the attach ended (\(firstExit)) but the pane did not start reconnecting")
        XCTAssertTrue(wait(10) { attaches() >= 2 }, "the pane did not attach again")
        XCTAssertTrue(wait(5) { !session.isReconnecting }, "the new connection was never taken")
        XCTAssertTrue(wait(3) { (session.terminalView?.readText(lastLines: 5) ?? "").contains("again") },
                      "the shown terminal is not the new connection")
    }

    /// 원격 tmux 탭(arch 워크스페이스)도 같은 길이다: ssh가 실패하면(255) 다시 붙기를 시작해야 한다. 터미널이
    /// 패널 명령을 login으로 감싸 0만 돌려주던 동안은 끊긴 ssh가 정상 종료로 보여 탭이 죽은 채 남았다.
    /// 이름을 풀 수 없는 호스트로 진짜 ssh를 띄워 255를 받는다(공유 연결은 건드리지 않는다).
    func testRemoteTmuxTabStartsReconnectingWhenSshFails() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let session = TerminalSession(kind: .tmuxMain, name: "qa", workingDirectory: NSHomeDirectory(),
                                      tmuxSessionName: "qa", remoteHost: "sm-reconnect-test.invalid")
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView = host
        window.orderFrontRegardless()
        host.show(session.getOrCreateTerminal())
        defer { session.cleanup(force: true); window.close() }
        let deadline = Date().addingTimeInterval(10)
        while !session.isReconnecting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(session.isReconnecting, "ssh failed but the remote tmux tab did not start reconnecting")
    }
}
