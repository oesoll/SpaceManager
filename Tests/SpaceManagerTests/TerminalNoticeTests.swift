import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// sm 패널의 터미널 알림(OSC 9)이 Fine 탭처럼 노치에 이 패널의 항목으로 올라가고, SEOL이 그 패널에 입력하면
/// 내려가는가. 진짜 Fine 대신 격리된 홈의 제어 소켓에 받는 쪽을 띄우고, 노치 파일은 Fine이 쓴 것처럼 둔다.
@MainActor
final class TerminalNoticeTests: XCTestCase {
    func testPaneNotificationGoesToTheNotchAndInputTakesItDown() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh — this would talk to the real Fine")
        try FileManager.default.createDirectory(at: FineControl.home, withIntermediateDirectories: true)
        let log = FineControl.home.appendingPathComponent("received.jsonl")
        try? FileManager.default.removeItem(at: log)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
        import os, socket, sys
        path, log = sys.argv[1], sys.argv[2]
        if os.path.exists(path): os.unlink(path)
        s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(4)
        while True:
            c, _ = s.accept(); line = c.makefile('rb').readline()
            open(log, 'ab').write(line); c.sendall(b'{"ok": true, "result": {}}\\n'); c.close()
        """, FineControl.socket, log.path]
        try server.run()
        defer { server.terminate(); try? FileManager.default.removeItem(at: FineControl.file) }
        func requests() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
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
        // 아치 에이전트 패널: 붙는 명령(가짜 sm-session)이 곧 알림을 낸다.
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("sm-session")
        try "#!/bin/sh\nsleep 0.5; printf '\\033]9;빌드가 끝났어요\\007'; exec sleep 60\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }
        let session = TerminalSession(kind: .shell, name: "qa", workingDirectory: NSHomeDirectory(),
                                      attachment: .agent(name: "qa", host: "arch-elsewhere", agent: nil))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView = host
        window.orderFrontRegardless()
        let view = session.getOrCreateTerminal()
        host.show(view)
        defer { session.cleanup(force: true); window.close() }

        XCTAssertTrue(wait(8) { requests().contains { $0["command"] as? String == "attention.post" } },
                      "the pane's notification never reached the notch: \(view.readText(lastLines: 8) ?? "")")
        let posted = try XCTUnwrap(requests().first { $0["command"] as? String == "attention.post" }?["args"] as? [String: String])
        XCTAssertEqual(posted["key"], session.terminalNoticeKey)
        XCTAssertEqual(posted["message"], "빌드가 끝났어요")
        XCTAssertEqual(posted["state"], "waiting")
        // 노치를 누르면 `sm reveal qa@arch-elsewhere`로 이 패널이 열리도록.
        XCTAssertEqual(posted["source"], "sm:qa")
        XCTAssertEqual(posted["host"], "arch-elsewhere")

        // Fine이 받아 파일에 쓴 것처럼 둔다 — sm은 그 파일로 노치에 무엇이 떠 있는지 안다.
        let item: [String: Any] = ["id": "n1", "key": session.terminalNoticeKey, "host": "arch-elsewhere", "source": "sm:qa",
                                   "fingerprint": "", "title": "qa", "message": "빌드가 끝났어요", "state": "waiting",
                                   "updatedAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: [item]).write(to: FineControl.file, options: .atomic)
        NotchOwner.shared.reloadFine()
        XCTAssertNotNil(PeerDirectory.shared.terminalNotice(for: session), "sm does not show the pane's notice")

        // SEOL이 그 패널에 친다 → 노치에서 내려간다(done).
        XCTAssertTrue(window.makeFirstResponder(view))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                 isARepeat: false, keyCode: 0))
        NSApp.sendEvent(key)
        XCTAssertTrue(wait(5) { requests().filter { $0["command"] as? String == "attention.post" }.count >= 2 },
                      "typing in the pane did not take the notice down")
        let cleared = requests().last { $0["command"] as? String == "attention.post" }?["args"] as? [String: String]
        XCTAssertEqual(cleared?["state"], "done")
        XCTAssertEqual(cleared?["key"], session.terminalNoticeKey)
    }
}
