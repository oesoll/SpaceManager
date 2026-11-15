import XCTest
@testable import SpaceManager

final class RemoteReconnectTests: XCTestCase {
    func testRemoteWorkspaceCreationKeepsItsHostOnRejectedSwitch() throws {
        let state = AppState(requestedWindowStateId: UUID())
        XCTAssertNil(state.createWorkspace(rootPath: "~/remote-only-\(UUID().uuidString)", customName: "remote", remoteHost: "arch"))
        let workspace = try XCTUnwrap(state.selectedWorkspace)
        defer { state.deleteWorkspace(workspace) }
        XCTAssertEqual(workspace.remoteHost, "arch")
        XCTAssertFalse(workspace.rootPath.hasPrefix("~"))
        // 맥에 그 폴더가 없으니 맥으로는 못 옮긴다 — 실행 위치는 그대로다.
        XCTAssertNotNil(state.setRemoteHost(workspace, to: ""))
        XCTAssertEqual(state.selectedWorkspace?.remoteHost, "arch")
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

    /// 세션을 보이는 패널(이 맥이든 아치든)은 attach가 끝나면 코드와 상관없이 다시 붙는다. attach는 세션이
    /// 멈추거나 잠들어도 끝나지 않고 기다리므로, 끝났다면 밖에서 끊긴 것이다 — 맥이 잠든 사이 ssh(255),
    /// SEOL이 쿼타 때문에 세션을 껐을 때 죽은 프로세스(11/01). 다시 붙어도 키를 누르기 전엔 세션이 시작되지 않는다.
    func testAgentPaneBacksOffAndRecoversAfterStableConnection() {
        let delays = (0...6).map { ReconnectPolicy.delay(attempt: $0, connectedFor: 1) }
        XCTAssertEqual(delays, [3, 6, 12, 24, 30, 30, 30])
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 6, connectedFor: 3600), 3)
    }

    /// 터미널은 패널 명령을 login으로 감싸고 login은 종료 코드를 삼킨다. 감싼 명령은 ssh 자리의 진짜 코드를
    /// 파일에 남기고 그 코드로 끝나야 한다.
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
