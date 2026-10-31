import AppKit
import XCTest
@testable import SpaceManager

/// 원격 tmux 탭이 끊겼을 때: 화면은 유지하고 상태만 바뀐다.
final class RemoteConnectionTests: XCTestCase {
    private func remoteTab() -> TerminalSession {
        TerminalSession(kind: .tmuxMain, name: "flat", workingDirectory: "/tmp",
                        tmuxSessionName: "flat", remoteHost: "arch")
    }

    func testDroppedConnectionKeepsTerminalAndBlocksStaleInput() throws {
        let session = remoteTab()
        defer { session.cleanup() }
        try "debug noise\nssh: connect to host arch port 22: Operation timed out\n\n"
            .write(toFile: session.sshErrorLogPath, atomically: true, encoding: .utf8)

        session.handleExit(exitCode: 255, connectedFor: 120)

        XCTAssertTrue(session.isReconnecting)
        XCTAssertNil(session.startError, "오류 화면이 터미널을 대체하면 끊기기 전 화면이 사라진다")
        XCTAssertEqual(session.lastConnectionFailure, "ssh: connect to host arch port 22: Operation timed out")
        XCTAssertFalse(session.acceptsInput, "얼어 있는 화면에 친 키가 재연결 뒤 원격으로 쏟아지면 안 된다")

        session.connectionResumed()

        XCTAssertFalse(session.isReconnecting)
        XCTAssertNil(session.lastConnectionFailure)
        XCTAssertTrue(session.acceptsInput)
    }

    func testFailedAttemptKeepsPreviousReasonWhenLogIsEmpty() {
        let session = remoteTab()
        defer { session.cleanup() }
        try? "ssh: Could not resolve hostname arch\n".write(toFile: session.sshErrorLogPath, atomically: true, encoding: .utf8)
        session.handleExit(exitCode: 255, connectedFor: 1)
        try? "".write(toFile: session.sshErrorLogPath, atomically: true, encoding: .utf8)
        session.handleExit(exitCode: 255, connectedFor: 1)
        XCTAssertEqual(session.lastConnectionFailure, "ssh: Could not resolve hostname arch")
        XCTAssertTrue(session.isReconnecting)
    }

    func testDeliberateDetachAndLocalExitsDoNotShowReconnect() {
        let remote = remoteTab()
        defer { remote.cleanup() }
        remote.handleExit(exitCode: 0, connectedFor: 300)
        XCTAssertFalse(remote.isReconnecting)

        let local = TerminalSession(kind: .tmuxMain, name: "x", workingDirectory: "/tmp", tmuxSessionName: "x")
        defer { local.cleanup() }
        local.handleExit(exitCode: 1, connectedFor: 300)
        XCTAssertFalse(local.isReconnecting)
        XCTAssertTrue(local.acceptsInput)
    }

    func testCleanupClearsReconnectAndRemovesLog() throws {
        let session = remoteTab()
        try "x\n".write(toFile: session.sshErrorLogPath, atomically: true, encoding: .utf8)
        session.handleExit(exitCode: 255, connectedFor: 1)
        session.cleanup()
        XCTAssertFalse(session.isReconnecting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.sshErrorLogPath))
    }

    func testOnlyRemoteTmuxSendsSshErrorsToLog() {
        let tmux = TerminalSession.launchArguments(kind: .tmuxMain, tmuxSessionName: "flat",
                                                   workingDirectory: "/nope", remoteHost: "arch",
                                                   remoteDirectory: .relativeToHome("myworld/flat"),
                                                   sshErrorLog: "/tmp/sm ssh.log")
        XCTAssertTrue(tmux[1].hasSuffix(" 2>'/tmp/sm ssh.log'"), tmux[1])
        // 재연결하지 않는 원격 셸은 "closed by remote host"가 화면에 남아야 끊긴 걸 안다.
        let shell = TerminalSession.launchArguments(kind: .shell, tmuxSessionName: nil,
                                                    workingDirectory: "/nope", remoteHost: "arch",
                                                    remoteDirectory: .absolute("/srv"),
                                                    sshErrorLog: "/tmp/sm ssh.log")
        XCTAssertFalse(shell[1].contains("sm ssh.log"))
        let local = TerminalSession.launchArguments(kind: .tmuxMain, tmuxSessionName: "x",
                                                    workingDirectory: "/tmp", sshErrorLog: "/tmp/sm ssh.log")
        XCTAssertFalse(local[1].contains("ssh"))
    }

    func testEachSessionObjectOwnsItsLog() {
        let original = remoteTab()
        let moved = original.retargeted(to: "nuc")
        defer { original.cleanup(); moved.cleanup() }
        XCTAssertEqual(original.id, moved.id)
        XCTAssertNotEqual(original.sshErrorLogPath, moved.sshErrorLogPath)
    }
}

/// 원격 tmux의 복사는 OSC 52로 온다. Mac 페이스트보드까지 닿아야 한다.
