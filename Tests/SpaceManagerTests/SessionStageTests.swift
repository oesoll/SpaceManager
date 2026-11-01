import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 잠든 세션 화면(SEOL 11/01, briefs/sleep-wake-ux.md)을 가짜 세션 층으로 끝까지 돌린다:
/// 잠든 패널은 마지막 화면 + 어두운 막 → 보면 깨우며(막이 숨쉼) 새 attach는 장면 아래에서 그리고 → 준비되고
/// 조용해지면 걷혀 그 자리에서 입력을 받는다(깨는 동안 친 키도 그때 넘어간다). 보는 중에 멈추면 얼리고 키를
/// 기다리며, attach가 밖에서 끊기면 마지막 화면을 둔 채 다시 붙는다.
@MainActor
final class SessionStageTests: XCTestCase {
    func testSleepingPaneWakesUnderItsLastScreenAndRevealsWhenReady() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh")
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dir = bin.path
        func put(_ name: String, _ text: String) throws { try text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        func get(_ name: String) -> String {
            ((try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try put("sm-session", """
        #!/bin/sh
        dir=$(dirname "$0")
        case "$1" in
        state) last=""; while true; do s=$(cat "$dir/ctl" 2>/dev/null); if [ "$s" != "$last" ]; then printf '{"name":"qa","state":"%s","at":0}\\n' "$s"; last=$s; fi; sleep 0.1; done ;;
        screen) cat "$dir/screen" ;;
        attach) n=$(cat "$dir/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$dir/count"; echo "$@" > "$dir/args"; printf 'attached %s\\n' "$n"; exec cat ;;
        esac
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/sm-session")
        try put("ctl", "asleep")
        try put("screen", "LAST SCREEN of qa\r\n")
        try? FileManager.default.removeItem(atPath: dir + "/count")
        defer { for name in ["sm-session", "ctl", "screen", "count", "args"] { try? FileManager.default.removeItem(atPath: dir + "/" + name) } }

        func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let session = TerminalSession(kind: .shell, name: "qa", workingDirectory: NSHomeDirectory(),
                                      attachment: .agent(name: "qa", host: "mac", agent: nil))
        let director = try XCTUnwrap(session.stageDirector)
        director.sessionLayer = dir + "/sm-session"
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 480, height: 160), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
        window.contentView = host
        window.orderFrontRegardless()
        host.showStage(director.stage)
        director.stage.layoutSubtreeIfNeeded()
        defer { session.cleanup(force: true); window.close() }
        let stage = director.stage

        // 1. 잠든 패널을 본다: 마지막 화면 + 막, 그 아래에서 깨우는 attach(--no-screen).
        director.begin()
        XCTAssertTrue(wait(5) { (stage.scene?.readText(lastLines: 5) ?? "").contains("LAST SCREEN") },
                      "the sleeping pane does not show its last screen")
        XCTAssertTrue(stage.isCovered)
        XCTAssertTrue(wait(5) { get("count") == "1" }, "looking at it did not open an attach to wake it")
        XCTAssertTrue(get("args").contains("--no-screen"), get("args"))
        XCTAssertEqual(stage.look, .waking)
        // 깨는 동안 친 키는 붙잡힌다.
        window.makeFirstResponder(stage)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                                 isARepeat: false, keyCode: 6))
        stage.keyDown(with: key)
        XCTAssertEqual(stage.heldKeyCount, 1)

        // 2. 준비됨 → 조용해지면 걷히고, 그 자리에서 입력을 받는다(붙잡은 키가 넘어간다).
        try put("ctl", "ready")
        XCTAssertTrue(wait(6) { !stage.isCovered }, "ready and quiet, but the veil stayed")
        XCTAssertTrue(session.terminalView === stage.live)
        XCTAssertTrue(wait(3) { (stage.live?.readText(lastLines: 5) ?? "").contains("z") }, "the key typed while waking was lost")

        // 3. 보는 중에 멈춤: 얼리고 키를 기다린다(저절로 깨우지 않는다).
        try put("ctl", "stopped")
        XCTAssertTrue(wait(3) { stage.isCovered && stage.look == .dimmed }, "stopped while shown, but not frozen")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(get("count"), "1", "a deliberate stop must not wake by itself")
        XCTAssertNil(session.terminalView)

        // 4. 멈춘 막 아래에서 키 → 깨운다.
        stage.keyDown(with: key)
        XCTAssertTrue(wait(3) { get("count") == "2" }, "a key in the stopped pane did not wake it")
        XCTAssertEqual(stage.look, .waking)
        try put("ctl", "ready")
        XCTAssertTrue(wait(6) { !stage.isCovered })

        // 5. attach가 밖에서 끊김(ssh 등): 마지막 화면을 둔 채 다시 붙는다.
        let pid = try XCTUnwrap(stage.live?.foregroundProcessIdentifier)
        kill(pid, SIGKILL)
        XCTAssertTrue(wait(3) { session.isReconnecting }, "a cut attach did not start reconnecting")
        // 끊긴 동안은 깨울 때와 같은 "연결 중" 모습(얼린 화면 + 막 + 빛 + 글).
        XCTAssertTrue(stage.isCovered)
        XCTAssertEqual(stage.look, .waking)
        XCTAssertEqual(stage.caption, "다시 연결하는 중")
        XCTAssertTrue(wait(8) { get("count") == "3" }, "it did not attach again")
        XCTAssertTrue(wait(6) { !stage.isCovered && !session.isReconnecting })
        XCTAssertNil(stage.caption)

        // 6. 오래 가려졌다(내림) 다시 봄: 얼린 화면 아래에서 다시 붙고, 빨리 붙으면 막 없이 그대로 걷힌다.
        director.park()
        XCTAssertTrue(stage.isCovered)
        XCTAssertEqual(stage.look, .clear, "a parked pane keeps its frame without a veil")
        XCTAssertNil(session.terminalView)
        // 창이 다시 보였다(가림이 걷힘 등) — 화면 갱신 없이도 다시 붙는다.
        session.resumeIfParked()
        XCTAssertTrue(wait(5) { get("count") == "4" }, "showing it again did not attach")
        XCTAssertTrue(wait(6) { !stage.isCovered }, "it did not lift after attaching again")
    }
}
