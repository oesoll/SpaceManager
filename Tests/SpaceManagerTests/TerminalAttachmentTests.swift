import XCTest
@testable import SpaceManager

final class TerminalAttachmentTests: XCTestCase {
    func testShellRunsTheLoginShellUnchanged() {
        XCTAssertNil(TerminalAttachment.shell.command())
    }

    /// 세션 층이 기기·소켓·ssh를 알아서 고른다. 화면 층은 이름@기기 하나만 넘긴다.
    func testAgentAttachesThroughPeerWithOneQuotedArgument() throws {
        let command = try XCTUnwrap(TerminalAttachment.agent(name: "it's-qa", host: "arch", agent: nil).command())
        XCTAssertEqual(command, #"exec sm-session attach 'it'\''s-qa@arch'"#)
        // 셸이 해석한 뒤 peer가 받는 인자를 실제로 본다.
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let peer = bin.appendingPathComponent("sm-session")
        try "#!/bin/sh\nfor a in \"$@\"; do printf 'arg=%s\\n' \"$a\"; done\n".write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: peer.path)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        shell.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
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
