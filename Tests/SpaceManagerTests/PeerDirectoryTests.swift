import XCTest
@testable import SpaceManager

final class PeerDirectoryTests: XCTestCase {
    /// `peer --all --json`이 실제로 내는 모양(10/31 맥에서 받은 행을 줄였다).
    private let sample = """
    {"peers": [
      {"id": "claude:aaa", "session": "aaa", "name": "flat-qa", "kind": "claude", "host": "arch",
       "cwd": "/home/x/flat", "title": null, "target": "%178", "state": "blocked", "reason": "permission",
       "since": 1793431000.5, "observed": 1793431001, "tmux_socket": "/tmp/tmux-1000/default",
       "group": "flat", "window": 1, "pane": 1},
      {"id": "claude:bbb", "session": "bbb", "name": "cld-claude-7", "kind": "claude", "host": "mac",
       "cwd": "/Users/x/cld", "title": null, "target": "fine:5151", "state": "waiting-on",
       "waiting_on": "sm-front", "reason": "tool", "since": 1793431100, "group": "Fine"},
      {"id": "codex:ccc", "session": "ccc", "name": "sol", "kind": "codex", "host": "mac",
       "target": "sm:3F2504E0-4F89-11D3-9A0C-0305E82C3301", "state": "something-new", "since": 1793431200}
    ], "hidden": 0, "unreachable": []}
    """

    func testDecodesTheLiveContract() throws {
        let listing = try PeerListing.decode(Data(sample.utf8))
        XCTAssertEqual(listing.peers.count, 3)
        let qa = listing.peers[0]
        XCTAssertEqual(qa.state, .blocked)
        XCTAssertEqual(qa.reason, "permission")
        XCTAssertEqual(qa.group, "flat")
        XCTAssertEqual(qa.window, 1)
        XCTAssertEqual(qa.since, Date(timeIntervalSince1970: 1793431000.5))
        XCTAssertEqual(qa.key, "arch/claude:aaa")
        XCTAssertEqual(listing.peers[1].state, .waitingOn)
        XCTAssertEqual(listing.peers[1].waitingOn, "sm-front")
        // 모르는 상태값 하나 때문에 목록 전체를 버리지 않는다.
        XCTAssertEqual(listing.peers[2].state, .unknown)
    }

    func testAttentionOrderPutsSEOLFirst() {
        XCTAssertGreaterThan(AgentAttention.blocked, .error)
        XCTAssertGreaterThan(AgentAttention.error, .done)
        XCTAssertGreaterThan(AgentAttention.done, .working)
        XCTAssertGreaterThan(AgentAttention.working, .idle)
        XCTAssertTrue(AgentAttention.done.needsSEOL)
        XCTAssertFalse(AgentAttention.working.needsSEOL)
    }

    func testDoneMeansFinishedAfterSEOLLastLooked() {
        let start = Date(timeIntervalSince1970: 1000)
        let directory = PeerDirectory(command: [], localHost: "mac")
        let working = agent(state: .working, since: start)
        directory.apply(PeerListing(peers: [working]), now: start.addingTimeInterval(1))
        XCTAssertEqual(directory.attention(of: working), .working)

        // 앱이 처음 본 순간 이미 쉬고 있던 에이전트는 "본 것"이다.
        let oldIdle = agent(id: "old", state: .idle, since: start.addingTimeInterval(-600))
        directory.apply(PeerListing(peers: [working, oldIdle]), now: start.addingTimeInterval(2))
        XCTAssertEqual(directory.attention(of: oldIdle), .idle)

        // 지켜본 뒤에 끝나면 done, 그 패널을 열면 idle로 돌아간다.
        let finished = agent(state: .idle, since: start.addingTimeInterval(30))
        directory.apply(PeerListing(peers: [finished, oldIdle]), now: start.addingTimeInterval(31))
        XCTAssertEqual(directory.attention(of: finished), .done)
        directory.setViewing(finished.key, owner: UUID())
        XCTAssertEqual(directory.attention(of: finished), .idle)
    }

    func testUnreachableHostKeepsItsLastRowsAsStale() {
        let directory = PeerDirectory(command: [], localHost: "mac")
        let remote = agent(id: "r", host: "arch", state: .working, since: Date())
        let local = agent(id: "l", host: "mac", state: .idle, since: Date())
        directory.apply(PeerListing(peers: [remote, local]))
        directory.apply(PeerListing(peers: [local], unreachable: ["ssh: connect to host arch: timed out"]))
        XCTAssertEqual(directory.agents.map(\.id), ["l", "r"])
        XCTAssertEqual(directory.agents.last?.isStale, true)
        // 다시 닿으면 새 행으로 바뀌고, 사라진 로컬 행은 남기지 않는다.
        directory.apply(PeerListing(peers: [remote]))
        XCTAssertEqual(directory.agents.map(\.id), ["r"])
        XCTAssertEqual(directory.agents.first?.isStale, false)
    }

    func testPaneMatchingUsesTheSmTarget() throws {
        let directory = PeerDirectory(command: [], localHost: "mac")
        let listing = try PeerListing.decode(Data(sample.utf8))
        directory.apply(listing)
        let pane = try XCTUnwrap(UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
        XCTAssertEqual(directory.agent(forPane: pane)?.name, "sol")
        XCTAssertNil(directory.agent(forPane: UUID()))
    }

    func testBadgeWordsComeFromTheReason() {
        let blocked = agent(state: .blocked, since: Date(), reason: "question")
        XCTAssertEqual(PaneBadge(agent: blocked, attention: .blocked).detail, "질문")
        let waiting = PeerAgent(id: "w", name: "lead", host: "mac", target: "sm:x", state: .waitingOn,
                                since: Date(), waitingOn: "review")
        XCTAssertEqual(PaneBadge(agent: waiting, attention: .waiting).detail, "review 대기")
        let now = Date()
        XCTAssertEqual(PaneBadge.age(since: now.addingTimeInterval(-20), now: now), "방금")
        XCTAssertEqual(PaneBadge.age(since: now.addingTimeInterval(-185), now: now), "3분")
        XCTAssertEqual(PaneBadge.age(since: now.addingTimeInterval(-7300), now: now), "2시간")
    }

    private func agent(id: String = "a", host: String = "mac", state: PeerState, since: Date,
                       reason: String? = nil) -> PeerAgent {
        PeerAgent(id: id, name: id, host: host, target: "sm:" + id, state: state, reason: reason, since: since)
    }
}
