import XCTest
@testable import SpaceManager

/// 노치를 Fine에서 sm으로 넘기는 길. 노치가 둘이거나 없는 순간이 없어야 한다:
/// Fine이 노치를 가진 동안 sm은 받은 알림을 그대로 Fine에 넘기고, Fine이 "unknown command"로 답하면(노치를
/// 걷어 낸 Fine) 이어받아 Fine에 떠 있던 것만 가져온다. 진짜 Fine 대신 격리된 홈의 `.fine/control.sock`에
/// 받는 쪽을 띄운다 — 진짜 노치를 건드리지 않는다.
@MainActor
final class NotchOwnerTests: XCTestCase {
    private var server: Process?
    private var log: URL { FineControl.home.appendingPathComponent("received.jsonl") }
    private var folder: URL!

    override func setUp() async throws {
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL == realHome.standardizedFileURL,
                      "run through scripts/test-isolated.sh — this would talk to the real Fine")
        try FileManager.default.createDirectory(at: FineControl.home, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: FineControl.file)
        // 앞 시험의 받는 쪽이 남긴 소켓 파일이 있으면 새 받는 쪽이 서기 전에 붙어 버린다.
        unlink(FineControl.socket)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.terminate()
        server?.waitUntilExit()
        server = nil
        unlink(FineControl.socket)
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Fine 자리에 받는 쪽을 띄운다. 모든 요청에 `reply`(JSON 한 줄)로 답하고 받은 줄을 남긴다.
    private func fakeFine(reply: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os, socket, sys
        path, log, reply = sys.argv[1], sys.argv[2], sys.argv[3]
        if os.path.exists(path): os.unlink(path)
        s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8)
        while True:
            c, _ = s.accept(); line = c.makefile('rb').readline()
            open(log, 'ab').write(line); c.sendall(reply.encode() + b'\\n'); c.close()
        """, FineControl.socket, log.path, reply]
        try process.run()
        server = process
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: FineControl.socket) && Date() < ready { usleep(20_000) }
    }

    private var received: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["command"] as? String
        }
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func owner() -> (NotchOwner, AttentionStore, PeerDirectory) {
        let store = AttentionStore(file: nil)
        let directory = PeerDirectory(command: [], localHost: "mac")
        let owner = NotchOwner(flag: folder.appendingPathComponent("notch-owner"), store: store, directory: directory,
                               showsNotch: false)
        return (owner, store, directory)
    }

    func testWhileFineOwnsTheNotchSmPassesNoticesThrough() throws {
        try fakeFine(reply: #"{"ok": true, "result": {"id": "from-fine"}}"#)
        let (owner, store, _) = owner()
        owner.probe()
        var answer: ControlResponse?
        owner.handle(ControlRequest(command: "attention.post", args: ["key": "k", "title": "t", "message": "m"])) { answer = $0 }
        XCTAssertTrue(wait { answer != nil })
        guard case .ok(let result) = answer else { return XCTFail("\(String(describing: answer))") }
        XCTAssertEqual((result as? [String: Any])?["id"] as? String, "from-fine")
        XCTAssertEqual(owner.owner, .fine)
        XCTAssertTrue(store.items.isEmpty, "sm kept a notice that Fine is showing")
        XCTAssertEqual(received, ["attention.status", "attention.post"])
    }

    func testWhenFineDropsItsNotchSmTakesOverWithWhatWasStillUp() throws {
        // Fine 노치에 떠 있던 것 하나(질문)와 지난 작업 줄 하나. Fine이 쓰는 모양 그대로.
        let items: [[String: Any]] = [
            ["id": "a", "key": "seol-notch:peer:qa", "host": "mac", "source": "sm:qa", "fingerprint": "",
             "title": "답 · qa", "message": "골라 줘", "state": "waiting", "updatedAt": 815_000_000.0, "workspace": ""],
            ["id": "b", "key": "claude:old", "host": "mac", "source": "", "fingerprint": "",
             "title": "cld · claude", "message": "", "state": "unknown", "updatedAt": 814_000_000.0],
        ]
        try JSONSerialization.data(withJSONObject: items).write(to: FineControl.file)
        try fakeFine(reply: #"{"ok": false, "error": "unknown command: attention.status"}"#)
        let (owner, store, directory) = owner()
        owner.probe()
        XCTAssertTrue(wait { owner.owner == .sm }, "Fine said it has no notch, but sm did not take it")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notch-owner"), encoding: .utf8), "sm\n")
        XCTAssertEqual(store.items.map(\.key), ["seol-notch:peer:qa"], "only what was still up comes over")
        XCTAssertEqual(store.items.first?.updatedAt, Date(timeIntervalSinceReferenceDate: 815_000_000))
        XCTAssertTrue(wait { directory.notices.map(\.key) == ["seol-notch:peer:qa"] }, "sm's panes do not follow sm's notch")

        // 이제 sm이 직접 받는다 — Fine에는 더 묻지 않는다.
        var answer: ControlResponse?
        owner.handle(ControlRequest(command: "attention.post", args: ["key": "k2", "title": "새 알림", "message": "m"])) { answer = $0 }
        XCTAssertTrue(wait { answer != nil })
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(received, ["attention.status"])

        owner.dismiss(store.items.first { $0.key == "k2" }!.id)
        XCTAssertEqual(store.items.map(\.key), ["seol-notch:peer:qa"])
    }

    func testAFineThatStillHasItsNotchIsAskedOnlyOnceAProxiedCallFails() throws {
        // 넘겨 주던 중 Fine이 노치를 걷은 판으로 바뀌었다: 넘긴 명령이 "unknown command"로 돌아오면 그 자리에서
        // 이어받아 sm이 처리한다(알림을 잃지 않는다).
        try fakeFine(reply: #"{"ok": false, "error": "unknown command: attention.post"}"#)
        let (owner, store, _) = owner()
        var answer: ControlResponse?
        owner.handle(ControlRequest(command: "attention.post", args: ["key": "k", "title": "t", "message": "m"])) { answer = $0 }
        XCTAssertTrue(wait { answer != nil })
        guard case .ok = answer else { return XCTFail("\(String(describing: answer))") }
        XCTAssertEqual(owner.owner, .sm)
        XCTAssertEqual(store.items.map(\.key), ["k"])
    }

    /// Fine이 노치를 가진 동안 sm 패널 표시는 Fine의 알림 파일을 따라간다(Fine은 파일을 통째로 바꿔 끼운다).
    func testWhileFineOwnsTheNotchSmFollowsItsFile() throws {
        func write(_ state: String) throws {
            let json = """
            [{"id":"WyJsb2NhbCJd","key":"seol-notch:peer:qa","host":"local","source":"sm:qa","fingerprint":"",
              "title":"답 · qa","message":"골라 줘","state":"\(state)","updatedAt":815187022.2,"workspace":""}]
            """
            try Data(json.utf8).write(to: FineControl.file, options: .atomic)
        }
        try write("waiting")
        try fakeFine(reply: #"{"ok": true, "result": {}}"#)
        let (owner, _, directory) = owner()
        owner.start()
        XCTAssertEqual(directory.notices.map(\.key), ["seol-notch:peer:qa"])
        XCTAssertEqual(directory.notices.first?.updatedAt, Date(timeIntervalSinceReferenceDate: 815187022.2))
        try write("done")
        XCTAssertTrue(wait { directory.notices.isEmpty }, "the notch file changed but sm did not follow")
        XCTAssertEqual(owner.owner, .fine)
    }

    func testOnceTakenTheNotchStaysWithSm() throws {
        try "sm\n".write(to: folder.appendingPathComponent("notch-owner"), atomically: true, encoding: .utf8)
        let (owner, _, _) = owner()
        XCTAssertEqual(owner.owner, .sm)
    }
}
