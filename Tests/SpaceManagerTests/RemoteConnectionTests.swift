import AppKit
import XCTest
@testable import SpaceManager

/// 세션 패널의 attach가 끊겼을 때: 화면은 유지하고 상태만 바뀐다. 셸 패널은 끝난 대로 둔다.
final class RemoteConnectionTests: XCTestCase {
    private func agentPane() -> TerminalSession {
        TerminalSession(name: "flat-main", workingDirectory: "/tmp",
                        attachment: .agent(name: "flat-main", host: "arch", agent: nil))
    }

    func testDroppedAttachKeepsTerminalAndBlocksStaleInput() {
        let session = agentPane()
        defer { session.cleanup() }
        session.handleExit(exitCode: 255, connectedFor: 120)

        XCTAssertTrue(session.isReconnecting)
        XCTAssertNil(session.startError, "오류 화면이 터미널을 대체하면 끊기기 전 화면이 사라진다")
        XCTAssertFalse(session.acceptsInput, "얼어 있는 화면에 친 키가 재연결 뒤 원격으로 쏟아지면 안 된다")

        session.connectionResumed()

        XCTAssertFalse(session.isReconnecting)
        XCTAssertTrue(session.acceptsInput)
    }

    func testShellPaneExitsDoNotShowReconnect() {
        let remote = TerminalSession(name: "shell@arch", workingDirectory: "/tmp", remoteHost: "arch")
        defer { remote.cleanup() }
        remote.handleExit(exitCode: 255, connectedFor: 300)
        XCTAssertFalse(remote.isReconnecting)
        XCTAssertTrue(remote.acceptsInput)
    }

    func testCleanupClearsReconnect() {
        let session = agentPane()
        session.handleExit(exitCode: 255, connectedFor: 1)
        session.cleanup()
        XCTAssertFalse(session.isReconnecting)
    }

    /// 세션 패널은 세션 층에 붙고, 원격 셸 패널은 그 기기의 작업 폴더에서 셸을 띄우고, 로컬 셸은 로그인 셸 그대로.
    func testLaunchArgumentsPerAttachment() {
        let agent = TerminalSession.launchArguments(attachment: .agent(name: "flat-main", host: "arch", agent: nil),
                                                    remoteHost: nil, workingDirectory: "/tmp")
        XCTAssertEqual(agent.first, "-lc")
        XCTAssertTrue(agent[1].contains("sm-session' attach 'flat-main@arch'"), agent[1])

        let remote = TerminalSession.launchArguments(attachment: .shell, remoteHost: "arch",
                                                     workingDirectory: NSHomeDirectory() + "/myworld/flat")
        XCTAssertEqual(remote.first, "-lc")
        XCTAssertTrue(remote[1].hasPrefix("exec ssh -t "), remote[1])
        XCTAssertTrue(remote[1].contains("myworld/flat"), remote[1])

        XCTAssertEqual(TerminalSession.launchArguments(attachment: .shell, remoteHost: nil, workingDirectory: "/tmp"), [])
    }

    func testRemoteDirectoryMovesHomePathsToTheRemoteHome() {
        XCTAssertEqual(RemoteShell.directory(forLocalPath: "/Users/me/proj", localHome: "/Users/me"), .relativeToHome("proj"))
        XCTAssertEqual(RemoteShell.directory(forLocalPath: "/Users/me", localHome: "/Users/me/"), .relativeToHome(""))
        XCTAssertEqual(RemoteShell.directory(forLocalPath: "/srv/x", localHome: "/Users/me"), .absolute("/srv/x"))
        XCTAssertEqual(RemoteShell.Directory.relativeToHome("a b").shellExpression, "\"$HOME/\"'a b'")
    }
}
