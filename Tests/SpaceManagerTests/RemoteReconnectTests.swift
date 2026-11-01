import XCTest
@testable import SpaceManager

final class RemoteReconnectTests: XCTestCase {
    func testRemoteWorkspaceCreationStartsWithRemoteTabsAndKeepsThemOnRejectedSwitch() throws {
        let state = AppState(requestedWindowStateId: UUID())
        XCTAssertNil(state.createWorkspace(rootPath: "~/remote-only-\(UUID().uuidString)", customName: "remote", remoteHost: "arch"))
        let workspace = try XCTUnwrap(state.selectedWorkspace)
        defer { state.deleteWorkspace(workspace) }
        XCTAssertEqual(workspace.remoteHost, "arch")
        XCTAssertFalse(workspace.rootPath.hasPrefix("~"))
        XCTAssertFalse(state.sessions.isEmpty)
        XCTAssertTrue(state.sessions.allSatisfy { $0.remoteHost == "arch" && !$0.isRunning })
        let ids = state.sessions.map(\.id)
        XCTAssertNotNil(state.setRemoteHost(workspace, to: ""))
        XCTAssertEqual(state.selectedWorkspace?.remoteHost, "arch")
        XCTAssertEqual(state.sessions.map(\.id), ids)
    }

    func testGeneratingActivityStaysOnItsOwnerHostAndExpires() {
        let now = Date()
        let index = GeneratingActivityIndex(entries: [
            "mac": .init(cwd: "/tmp/mac", modified: now),
            "arch": .init(cwd: "/tmp/project", modified: now, host: "arch"),
            "old": .init(cwd: "/tmp/old", modified: now.addingTimeInterval(-10), host: "arch"),
            "future": .init(cwd: "/tmp/future", modified: now.addingTimeInterval(10), host: "arch")
        ])
        XCTAssertEqual(index.directoriesByHost(now: now)[""], ["/tmp/mac"])
        XCTAssertEqual(index.directoriesByHost(now: now)["arch"], ["/tmp/project"])
        XCTAssertTrue(index.directoriesByHost(now: now.addingTimeInterval(5)).isEmpty)
    }

    func testMissingMacCheckoutDoesNotSilentlyFallBackToHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootPath: root.path, remoteHost: "arch")
        XCTAssertNotNil(workspace.executionLocationError(host: nil))
        XCTAssertNil(workspace.executionLocationError(host: "arch"))
        try Data().write(to: root)
        XCTAssertNotNil(workspace.executionLocationError(host: ""))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(workspace.executionLocationError(host: nil))
    }

    func testConnectionLossBacksOffAndRecoversAfterStableConnection() {
        let delays = (0...6).map {
            RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: "arch", exitCode: 255,
                                        attempt: $0, connectedFor: 1)
        }
        XCTAssertEqual(delays, [3, 6, 12, 24, 30, 30, 30])
        XCTAssertEqual(RemoteReconnectPolicy.delay(kind: .tmuxExtra, remoteHost: "arch", exitCode: -1,
                                                   attempt: 6, connectedFor: 40), 3)
    }

    func testExplicitDetachAndEphemeralShellsDoNotRestart() {
        XCTAssertNil(RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: "arch", exitCode: 0, attempt: 0, connectedFor: 1))
        for kind: TabKind in [.shell, .quick] {
            XCTAssertNil(RemoteReconnectPolicy.delay(kind: kind, remoteHost: "arch", exitCode: 255, attempt: 0, connectedFor: 1))
        }
        XCTAssertNil(RemoteReconnectPolicy.delay(kind: .tmuxMain, remoteHost: nil, exitCode: 1, attempt: 0, connectedFor: 1))
    }

    /// 세션을 보이는 패널(이 맥이든 아치든)은 attach가 끝나면 코드와 상관없이 다시 붙는다. attach는 세션이
    /// 멈추거나 잠들어도 끝나지 않고 기다리므로, 끝났다면 밖에서 끊긴 것이다 — 맥이 잠든 사이 ssh(255),
    /// SEOL이 쿼타 때문에 세션을 껐을 때 죽은 프로세스(11/01). 다시 붙어도 키를 누르기 전엔 세션이 시작되지 않는다.
    func testAgentPaneAlwaysAttachesAgain() {
        for code: Int32 in [0, 1, 143, 255] {
            XCTAssertEqual(RemoteReconnectPolicy.delay(kind: .shell, remoteHost: nil, exitCode: code, attempt: 0,
                                                       connectedFor: 3600, agentPane: true), 3, "exit \(code)")
        }
        // 붙자마자 계속 끝나면 30초까지 늦춘다(없어진 세션에 1초마다 붙지 않게).
        XCTAssertEqual(RemoteReconnectPolicy.delay(kind: .shell, remoteHost: nil, exitCode: 1, attempt: 9,
                                                   connectedFor: 1, agentPane: true), 30)
        // 세션이 아닌 셸 패널은 그대로 닫힌 채 둔다.
        XCTAssertNil(RemoteReconnectPolicy.delay(kind: .shell, remoteHost: nil, exitCode: 255, attempt: 0, connectedFor: 1))
    }

    func testFailedManagedRestoreDoesNotCreateAnEmptyReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".config/systemd/user/tmux-server.service.d/persistence.conf")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("systemctl", "exit 1"), ("tmux", "touch \"$HOME/tmux-was-called\"; exit 0")] {
            let file = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", TmuxBootstrap.remoteStartupScript(sessionName: "project", remoteDirectory: .relativeToHome("project"))]
        process.environment = ["HOME": root.path, "PATH": bin.path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tmux-was-called").path))
    }

    func testHostChangePreservesExtraTabIdentityAndSession() {
        let original = TerminalSession(kind: .tmuxExtra, name: "review", workingDirectory: "/Users/me/project", tmuxSessionName: "project-3")
        let remote = original.retargeted(to: "arch")
        XCTAssertEqual(remote.id, original.id)
        XCTAssertEqual(remote.name, "review")
        XCTAssertEqual(remote.kind, .tmuxExtra)
        XCTAssertEqual(remote.tmuxSessionName, "project-3")
        XCTAssertEqual(remote.workingDirectory, original.workingDirectory)
        XCTAssertEqual(remote.remoteHost, "arch")
        XCTAssertNil(remote.retargeted(to: nil).remoteHost)
    }

    func testRetargetRenamesOnlyDefaultShellNames() {
        let shell = TerminalSession(kind: .shell, name: "zsh", workingDirectory: "/tmp")
        let remote = shell.retargeted(to: "arch")
        XCTAssertEqual(remote.name, "shell@arch")
        XCTAssertEqual(remote.retargeted(to: nil).name, "zsh")
        let tmux = TerminalSession(kind: .tmuxExtra, name: "flat-2", workingDirectory: "/tmp", tmuxSessionName: "flat-2")
        XCTAssertEqual(tmux.retargeted(to: "arch").name, "flat-2")
        [shell, remote, tmux].forEach { $0.cleanup() }
    }

    /// 터미널은 패널 명령을 login으로 감싸고 login은 종료 코드를 삼킨다. 감싼 명령은 ssh 자리의 진짜 코드를
    /// 파일에 남기고 그 코드로 끝나야 한다 — 원격 tmux 탭의 `exec ssh … 2>log` 꼴도 그대로.
    func testWrappedCommandRecordsTheRealExitCode() throws {
        let path = NSTemporaryDirectory() + "sm-exit-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let wrapped = TerminalAttachment.recordingExit("exec sh -c 'exit 255' 2>" + TerminalAttachment.quote(path + ".err"), to: path)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", wrapped]
        try shell.run()
        shell.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path + ".err")
        XCTAssertEqual(shell.terminationStatus, 255)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "255")
    }
}
