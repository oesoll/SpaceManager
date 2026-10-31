import XCTest
@testable import SpaceManager

final class TerminalAttachmentTests: XCTestCase {
    func testShellRunsTheLoginShellUnchanged() {
        XCTAssertNil(TerminalAttachment.shell.command(localHost: "mac") { _ in nil })
    }

    func testLocalAgentAttachesInPlace() {
        let command = TerminalAttachment.hold(socket: "/s/a.sock", host: "mac", agent: nil)
            .command(localHost: "mac") { _ in nil }
        XCTAssertEqual(command, "exec peer-hold attach --sock '/s/a.sock'")
    }

    /// 두 번의 셸 해석(로컬 셸 → 원격 로그인 셸)을 거친 뒤 peer-hold가 받는 인자를 실제로 본다.
    func testRemoteAgentAttachesBehindSshWithTheHostAlias() throws {
        let socket = "/home/x/hold/it's here.sock"
        let command = try XCTUnwrap(TerminalAttachment.hold(socket: socket, host: "nuc", agent: "claude:a")
            .command(localHost: "mac") { $0 == "nuc" ? "nuc-pet" : nil })
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        // 가짜 ssh는 별칭을 찍고 원격 명령을 셸에 넘기며, 가짜 peer-hold는 받은 인자를 한 줄씩 찍는다.
        let ssh = "#!/bin/sh\nshift\nprintf 'host=%s\\n' \"$1\"\nshift\nexec /bin/sh -c \"$1\"\n"
        let hold = "#!/bin/sh\nfor a in \"$@\"; do printf 'arg=%s\\n' \"$a\"; done\n"
        for (name, body) in [("ssh", ssh), ("peer-hold", hold)] {
            let url = bin.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        shell.environment = ["PATH": bin.path + ":/usr/bin:/bin", "SHELL": "/bin/sh"]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        shell.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(printed, "host=nuc-pet\narg=attach\narg=--sock\narg=\(socket)\n")
    }
}
