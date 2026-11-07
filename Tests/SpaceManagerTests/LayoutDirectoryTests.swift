import XCTest
@testable import SpaceManager

final class LayoutDirectoryTests: XCTestCase {
    private func layoutLine(version: Int) -> String {
        #"{"schema": 1, "workspace": "flat", "host": "arch", "cwd": "/w", "version": \#(version), "active_tab": "t", "tabs": [{"id": "t", "name": "main", "focus": "p", "zoom": null, "root": {"pane": "p"}}], "panes": {"p": {"session": "flat-main"}}}"#
    }

    /// 원격 배치: watch가 낸 배치 줄을 받고 heartbeat 줄은 건너뛴다. watch가 끝나면 다시 띄워 새 version을 받는다.
    func testRemoteWatchIsFollowedAndRestarted() throws {
        // 격리 없이 돌면 진짜 세션 층을 가짜로 덮어썼다가 지운다. 그동안 그 기기의 sm이 전부 멎는다(11/01, 11/07).
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh")
        let bin = URL(fileURLWithPath: NSHomeDirectory() + "/.smux/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent("watch-count-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        n=$(cat '\(counter.path)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(counter.path)'
        echo '{"heartbeat": 1, "version": 0, "workspace": "flat"}'
        if [ "$n" = 1 ]; then echo '\(layoutLine(version: 1))'; else echo '\(layoutLine(version: 2))'; sleep 30; fi
        """
        let fake = bin.appendingPathComponent("sm-session")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake); try? FileManager.default.removeItem(at: counter) }

        let directory = LayoutDirectory(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let owner = UUID()
        directory.setRemote(["flat@arch"], owner: owner)
        let first = Date().addingTimeInterval(5)
        while directory.layouts["flat@arch"] == nil && Date() < first { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(directory.layouts["flat@arch"]?.version, 1)
        XCTAssertTrue(directory.isSettled("flat@arch", remote: true))
        // 첫 watch는 바로 끝난다 → 4초 뒤 다시 떠서 version 2를 보낸다.
        let second = Date().addingTimeInterval(9)
        while directory.layouts["flat@arch"]?.version != 2 && Date() < second { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(directory.layouts["flat@arch"]?.version, 2)
        directory.setRemote([], owner: owner)
    }
}
