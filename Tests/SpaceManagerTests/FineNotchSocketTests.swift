import XCTest
@testable import SpaceManager

/// sm이 Fine 제어 소켓에 보내는 말이 Fine 규약(JSON 한 줄, `{"command","args"}`)대로 가는가. 진짜 Fine 대신
/// 격리된 홈의 `.fine/control.sock`에 받는 쪽을 띄운다 — 진짜 노치를 건드리지 않는다.
final class FineNotchSocketTests: XCTestCase {
    func testDismissAndPostReachFineAsOneJSONLine() throws {
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh — this would talk to the real Fine")
        try FileManager.default.createDirectory(at: FineNotch.home, withIntermediateDirectories: true)
        let log = FineNotch.home.appendingPathComponent("received.jsonl")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
        import os, socket, sys
        path, log = sys.argv[1], sys.argv[2]
        if os.path.exists(path): os.unlink(path)
        s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(4)
        for _ in range(2):
            c, _ = s.accept(); line = c.makefile('rb').readline()
            open(log, 'ab').write(line); c.sendall(b'{"ok": true, "result": {}}\\n'); c.close()
        """, FineNotch.socket, log.path]
        try server.run()
        defer { server.terminate() }
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: FineNotch.socket) && Date() < ready { usleep(20_000) }

        var results: [Bool] = []
        FineNotch.call("attention.dismiss", ["id": "abc"]) { results.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while results.count < 1 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        FineNotch.post(["key": "terminal:x", "message": "끝났어요", "state": "waiting"]) { results.append($0) }
        while results.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(results, [true, true])

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(requests.first?["command"] as? String, "attention.dismiss")
        XCTAssertEqual((requests.first?["args"] as? [String: String])?["id"], "abc")
        XCTAssertEqual(requests.last?["command"] as? String, "attention.post")
        XCTAssertEqual((requests.last?["args"] as? [String: String])?["message"], "끝났어요")
    }
}
