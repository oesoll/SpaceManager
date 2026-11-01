import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 잠든 세션 화면의 시연 녹화(SEOL에게 보이려고). 평소에는 건너뛴다:
///   SM_CAPTURE=1 SM_STAGE_DEMO=<화면 바이트 파일> SM_STAGE_DEMO_OUT=<out.mov> SM_WINREC=<창 녹화기>
/// 패널 하나를 sm과 같은 무대·감독으로 띄우고, 깨어 있음 → 보는 중 멈춤 → 키로 깨우기(빛이 가장자리를 돎,
/// 그 아래에서 에이전트가 화면을 다시 채우며 버벅임) → 준비되면 걷힘을 창만 녹화한다.
@MainActor
final class StageDemoTests: XCTestCase {
    func testRecordWakeDemo() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SM_CAPTURE"] == "1", let screen = env["SM_STAGE_DEMO"], let out = env["SM_STAGE_DEMO_OUT"],
              let recorder = env["SM_WINREC"] else { throw XCTSkip("demo only") }
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dir = bin.path
        func put(_ name: String, _ text: String) throws { try text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        try FileManager.default.copyItem(atPath: screen, toPath: dir + "/screen")
        // 깨울 때의 attach는 Claude가 다시 뜨는 모습을 흉내 낸다: 시작 글, 지우기, 화면을 조각조각 채우기.
        try put("sm-session", """
        #!/bin/sh
        dir=$(dirname "$0")
        case "$1" in
        state) last=""; while true; do s=$(cat "$dir/ctl" 2>/dev/null); if [ "$s" != "$last" ]; then printf '{"name":"demo","state":"%s","at":0}\\n' "$s"; last=$s; fi; sleep 0.05; done ;;
        screen) cat "$dir/screen" ;;
        attach) n=$(cat "$dir/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$dir/count"
          if [ "$n" -gt 1 ]; then
            printf 'Claude Code 다시 시작 중…\\r\\n'; sleep 0.8; printf '\\033[2J\\033[H'; sleep 0.3
            split -b 9000 "$dir/screen" "$dir/part."; for p in "$dir"/part.*; do cat "$p"; sleep 0.12; done; rm -f "$dir"/part.*
          else cat "$dir/screen"; fi
          exec cat >/dev/null ;;
        esac
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/sm-session")
        try put("ctl", "ready")
        try? FileManager.default.removeItem(atPath: dir + "/count")
        defer { for name in ["sm-session", "ctl", "screen", "count"] { try? FileManager.default.removeItem(atPath: dir + "/" + name) } }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let session = TerminalSession(kind: .shell, name: "demo", workingDirectory: NSHomeDirectory(),
                                      attachment: .agent(name: "demo", host: "mac", agent: nil))
        let director = try XCTUnwrap(session.stageDirector)
        director.sessionLayer = dir + "/sm-session"
        let size = NSSize(width: 980, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "sm — 잠든 세션 깨우기"
        window.isReleasedWhenClosed = false
        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.appearance = NSAppearance(named: .darkAqua)
        card.layer?.backgroundColor = NSColor(red: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x1e / 255.0, alpha: 1).cgColor
        window.appearance = NSAppearance(named: .darkAqua)
        let host = TerminalHostView(frame: card.bounds.insetBy(dx: 14, dy: 12))
        card.addSubview(host)
        window.contentView = card
        window.orderFrontRegardless()
        host.showStage(director.stage)
        director.stage.layoutSubtreeIfNeeded()
        defer { session.cleanup(force: true); window.close() }

        func run(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let record = Process()
        record.executableURL = URL(fileURLWithPath: recorder)
        record.arguments = [String(window.windowNumber), "17", out]
        director.begin()
        run(1.2)                         // 깨어 있는 화면
        try record.run()
        run(1.5)
        try put("ctl", "stopped")        // 보는 중에 멈춤: 얼고 막이 내린다
        run(3.0)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                 isARepeat: false, keyCode: 0))
        director.stage.keyDown(with: key) // 키 → 깨는 중(빛이 돈다, 아래에서 다시 채움)
        run(7.0)
        try put("ctl", "ready")          // 준비됨 → 조용해지면 걷힘
        run(4.0)
        record.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }
}
