import XCTest
@testable import SpaceManager

/// 패널에 넘기는 PATH는 사용자의 대화형 셸이 만드는 것이다 — .zshrc에서 더한 자리가 들어 있어야
/// 앱이 Finder로 떠도 패널 안에서 ccv 같은 명령을 찾는다(11/01).
final class UserShellEnvironmentTests: XCTestCase {
    func testReadsThePathTheInteractiveShellBuilds() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let rc = home.appendingPathComponent(".zshrc")
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(home.standardizedFileURL == realHome.standardizedFileURL, "run through scripts/test-isolated.sh")
        try "echo 'noise from rc'\nexport PATH=\"$HOME/only-in-rc:$PATH\"\n".write(to: rc, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rc) }
        let path = try XCTUnwrap(UserShellEnvironment.resolve(shell: "/bin/zsh"))
        XCTAssertTrue(path.split(separator: ":").contains { $0 == home.path + "/only-in-rc" }, path)
        XCTAssertFalse(path.contains("noise"))
    }

    func testAShellThatHangsFallsBack() {
        XCTAssertNil(UserShellEnvironment.resolve(shell: "/bin/sleep", timeout: 0.3))
        XCTAssertTrue(UserShellEnvironment.fallback.contains(NSHomeDirectory() + "/bin"))
    }
}
