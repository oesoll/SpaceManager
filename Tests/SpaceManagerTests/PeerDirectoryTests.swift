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
        XCTAssertGreaterThan(AgentAttention.error, .working)
        XCTAssertGreaterThan(AgentAttention.working, .idle)
        XCTAssertTrue(AgentAttention.error.needsSEOL)
        XCTAssertFalse(AgentAttention.working.needsSEOL)
    }

    /// SEOL 차례인지는 노치가 정한다. 턴이 끝났다고 sm이 따로 "끝남"을 올리지 않는다 — 노치에 없는 표시는
    /// 두 앱을 어긋나게 했다(11/01). 에이전트가 seol-notch로 부르면 노치와 sm에 같이 뜬다.
    func testNotchDecidesWhoNeedsSEOL() {
        let directory = PeerDirectory(command: [], localHost: "mac")
        let finished = agent(id: "claude:s1", name: "sm-front", state: .idle, since: Date())
        directory.apply(PeerListing(peers: [finished]))
        XCTAssertEqual(directory.attention(of: finished), .idle, "a turn that ended is not SEOL's turn by itself")

        // 맥의 sm 세션이 seol-notch로 불렀다: host는 local, key 끝에 그 칸의 표시, source는 sm:이름.
        let call = notice(key: "seol-notch:peer:sm-front", host: "local", source: "sm:sm-front",
                          title: "설치 확인 · sm-front", message: "새 빌드를 깔았어요")
        directory.applyNotch([call, notice(key: "ask:nuc-1", host: "nuc", title: "결정함")])
        XCTAssertEqual(directory.attention(of: finished), .blocked)
        let badge = PaneBadge(agent: finished, attention: directory.attention(of: finished), notice: directory.notice(for: finished))
        XCTAssertEqual(badge.detail, "설치 확인", "the pane shows the notch's bold line")
        XCTAssertEqual(badge.since, call.updatedAt)
        XCTAssertTrue(badge.help.contains("새 빌드를 깔았어요"))

        // 노치에서 내려가면(SEOL이 지웠거나 그 칸에 입력했다) sm에서도 내려간다.
        directory.applyNotch([])
        XCTAssertEqual(directory.attention(of: finished), .idle)
    }

    /// 올린 쪽마다 에이전트를 가리키는 칸이 다르다 — 훅은 세션 id, tmux 칸은 `%N`, 다른 기기는 그 host.
    func testNoticeFindsItsAgentByEachAddress() {
        let hook = notice(key: "claude:s2", host: "arch", source: "37o8", message: "권한 확인이 필요합니다: Bash")
        let onArch = agent(id: "claude:s2", name: "flat-qa", host: "arch", state: .blocked, since: Date())
        XCTAssertTrue(hook.refers(to: onArch, localHost: "mac"))
        XCTAssertEqual(hook.shortLabel, "권한")
        let sameIdOtherHost = agent(id: "claude:s2", name: "flat-qa", host: "mac", state: .blocked, since: Date())
        XCTAssertFalse(hook.refers(to: sameIdOtherHost, localHost: "mac"))

        let tmux = notice(key: "seol-notch:%178", host: "arch", source: "%178", title: "답 · flat")
        let inTmux = PeerAgent(id: "claude:s3", name: "flat-main", host: "arch", target: "%178", state: .idle, since: Date())
        XCTAssertTrue(tmux.refers(to: inTmux, localHost: "mac"))
        XCTAssertFalse(tmux.refers(to: onArch, localHost: "mac"))

        // sm 패널 target(sm:<패널>)은 이름이 아니라 위치다.
        let pane = PeerAgent(id: "claude:s4", name: "sol", host: "mac", target: "sm:p-0696dd0da05874c8", state: .idle, since: Date())
        XCTAssertTrue(notice(key: "seol-notch:x", host: "local", source: "sm:p-0696dd0da05874c8").refers(to: pane, localHost: "mac"))
        XCTAssertFalse(notice(key: "seol-notch:x", host: "local", source: "sm:other").refers(to: pane, localHost: "mac"))
    }

    /// 권한·질문으로 막힌 에이전트: 노치에서 지우면 에이전트가 아직 막혀 있어도 sm에서 내린다(두 앱이 같은 것을
    /// 보인다). 노치에 아예 오지 않은 막힘(맥이 잠든 사이 배달이 빠짐)은 peer 상태대로 sm에 남는다.
    func testDismissingInTheNotchClearsTheBlockedPane() {
        let directory = PeerDirectory(command: [], localHost: "mac")
        let start = Date(timeIntervalSince1970: 2000)
        let blocked = agent(id: "claude:s5", name: "qa", state: .blocked, since: start, reason: "permission")
        directory.apply(PeerListing(peers: [blocked]))
        XCTAssertEqual(directory.attention(of: blocked), .blocked, "a block the notch never got still shows")

        directory.applyNotch([notice(key: "claude:s5", host: "mac", message: "권한 확인이 필요합니다: Bash")])
        XCTAssertEqual(directory.attention(of: blocked), .blocked)
        directory.applyNotch([])
        directory.apply(PeerListing(peers: [blocked]))
        XCTAssertEqual(directory.attention(of: blocked), .idle, "dismissed in the notch, still shown in sm")

        // 다음 막힘은 새로 뜬다.
        let again = agent(id: "claude:s5", name: "qa", state: .blocked, since: start.addingTimeInterval(60), reason: "question")
        directory.apply(PeerListing(peers: [again]))
        XCTAssertEqual(directory.attention(of: again), .blocked)
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

    private func agent(id: String = "a", name: String? = nil, host: String = "mac", state: PeerState, since: Date,
                       reason: String? = nil) -> PeerAgent {
        PeerAgent(id: id, name: name ?? id, host: host, target: "sm:" + id, state: state, reason: reason, since: since)
    }

    private func notice(key: String, host: String, source: String = "", title: String = "에이전트",
                        message: String = "", state: AttentionState = .waiting) -> AttentionItem {
        AttentionItem(id: key + host, key: key, host: host, source: source, fingerprint: "", title: title,
                      message: message, state: state, updatedAt: Date(timeIntervalSinceReferenceDate: 815_000_000))
    }
}
