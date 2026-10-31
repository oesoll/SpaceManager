import XCTest
@testable import SpaceManager

final class TerminalAttachmentTests: XCTestCase {
    func testShellRunsTheLoginShellUnchanged() {
        XCTAssertNil(TerminalAttachment.shell.command())
    }

    /// 세션 층이 기기·소켓·ssh를 알아서 고른다. 화면 층은 이름@기기 하나만 넘긴다.
    func testAgentAttachesThroughPeerWithOneQuotedArgument() throws {
        let command = try XCTUnwrap(TerminalAttachment.agent(name: "it's-qa", host: "arch", agent: nil).command())
        XCTAssertEqual(command, "exec '" + NSHomeDirectory() + "/.smux/bin/sm-session' attach " + #"'it'\''s-qa@arch'"#)
        // 셸이 해석한 뒤 세션 층이 받는 인자를 실제로 본다. PATH에 ~/.smux/bin이 없어도 붙어야 한다(Finder로
        // 뜬 앱). 가짜 sm-session은 그 경로에 둔다 — 실제 홈이면 진짜를 덮으므로 격리된 홈에서만.
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh")
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let peer = bin.appendingPathComponent("sm-session")
        defer { try? FileManager.default.removeItem(at: peer) }
        try "#!/bin/sh\nfor a in \"$@\"; do printf 'arg=%s\\n' \"$a\"; done\n".write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: peer.path)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        shell.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "arg=attach\narg=it's-qa@arch\n")
    }

    /// 로그인 셸 인자를 Ghostty 명령 한 줄로. 지울 변수는 env -u로 감싼다.
    func testGhosttyLaunchQuotesArgumentsAndUnsetsVariables() {
        let plain = TerminalSession.ghosttyLaunch(arguments: [], environment: ([:], []), workingDirectory: "/w", shell: "/bin/zsh")
        XCTAssertNil(plain.command)
        let script = TerminalSession.ghosttyLaunch(arguments: ["-lc", "exec tmux attach -t 'a b'"],
                                                   environment: (["SM_PANE_ID": "X"], ["ANTHROPIC_BASE_URL"]),
                                                   workingDirectory: "/w", shell: "/bin/zsh")
        XCTAssertEqual(script.command, #"'/usr/bin/env' '-u' 'ANTHROPIC_BASE_URL' '/bin/zsh' '-lc' 'exec tmux attach -t '\''a b'\'''"#)
        XCTAssertEqual(script.environment, ["SM_PANE_ID": "X"])
    }
}
