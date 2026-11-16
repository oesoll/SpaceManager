import XCTest
@testable import SpaceManager

/// 패널 여럿이 기기 하나의 상태 스트림을 나눠 쓴다: 프로세스는 하나, 이름은 `+NAME`/`-NAME` 줄로 오간다.
@MainActor
final class SessionStateHubTests: XCTestCase {
    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testManyNamesShareOneProcess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("sm-session").path
        // 뜰 때마다 starts에 한 줄, 받은 줄은 lines에 남기고, +NAME마다 그 이름의 상태를 답한다.
        try """
        #!/bin/sh
        dir=$(dirname "$0")
        echo "$*" >> "$dir/starts"
        while read l; do echo "$l" >> "$dir/lines"; case "$l" in +*) printf '{"name":"%s","state":"ready","at":0}\\n' "${l#+}" ;; esac; done
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        SessionStateHub.stopAll()
        defer { SessionStateHub.stopAll() }

        let hub = SessionStateHub.shared(host: "arch", executable: script)
        var heard: [String: [String]] = [:]
        let a = hub.subscribe("a", onState: { heard["a", default: []].append($0) }, onUnsupported: {})
        _ = hub.subscribe("b", onState: { heard["b", default: []].append($0) }, onUnsupported: {})
        // 같은 세션을 두 번째 패널이 본다: 다음 줄을 기다리지 않고 마지막 상태를 바로 받는다.
        XCTAssertTrue(wait(3) { heard["a"] == ["ready"] && heard["b"] == ["ready"] }, "\(heard)")
        _ = hub.subscribe("a", onState: { heard["a2", default: []].append($0) }, onUnsupported: {})
        XCTAssertTrue(wait(3) { heard["a2"] == ["ready"] }, "\(heard)")
        hub.unsubscribe("a", a)

        let read = { (name: String) in
            ((try? String(contentsOfFile: dir.appendingPathComponent(name).path, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        XCTAssertEqual(read("starts"), ["state - --watch --host arch"], "one process for every name")
        // a를 보는 패널이 하나 남았으니 -a는 아직 보내지 않는다.
        XCTAssertTrue(wait(2) { read("lines") == ["+a", "+b"] }, "\(read("lines"))")
    }

    /// 옛 세션 층(인자 오류, 2)이면 패널마다 감시로 돌아가고, 닿지 않는 기기(ssh 255)는 다시 붙는다.
    func testAnOldLayerFallsBackButAnUnreachableHostRetries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func fake(_ name: String, _ body: String) throws -> String {
            let path = dir.appendingPathComponent(name).path
            try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        SessionStateHub.stopAll()
        defer { SessionStateHub.stopAll() }

        let old = try fake("old", "echo 'sm state: error: unrecognized arguments: --host mac' >&2; exit 2")
        var fellBack = false
        _ = SessionStateHub.shared(host: "mac", executable: old).subscribe("a", onState: { _ in }, onUnsupported: { fellBack = true })
        XCTAssertTrue(wait(3) { fellBack }, "an old session layer did not fall back to per-pane watching")

        // 처음 두 번은 닿지 않고(255), 세 번째에 붙는다.
        let flaky = try fake("flaky", """
        dir=$(dirname "$0"); n=$(cat "$dir/tries" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$dir/tries"
        [ $n -lt 3 ] && exit 255
        while read l; do case "$l" in +*) printf '{"name":"%s","state":"ready","at":0}\\n' "${l#+}" ;; esac; done
        """)
        var states: [String] = [], unsupported = false
        _ = SessionStateHub.shared(host: "arch", executable: flaky).subscribe("b", onState: { states.append($0) },
                                                                             onUnsupported: { unsupported = true })
        XCTAssertTrue(wait(12) { states == ["ready"] }, "an unreachable host was not retried: \(states)")
        XCTAssertFalse(unsupported, "an unreachable host was taken for an old session layer")
    }
}
