import AppKit
import Foundation

/// 세션 층이 아는 이 워크스페이스의 세션 하나(`sm ls --ws WS --json`의 행).
struct WorkspaceSession: Equatable {
    let name: String
    let host: String
    /// claude | codex | omo | shell …
    let kind: String
    /// running | ended | dead …
    let status: String
    let state: PeerState
    /// 묶인 패널 id(있으면).
    let pane: String?
    /// 이 세션을 띄운 쪽: `기기/peer id`(`arch/claude:<세션>`), 또는 이름·`이름@기기`.
    let parent: String?
    /// peer가 이 세션을 부르는 id(`claude:<세션>`).
    let peerID: String?
    let lastActive: Date?

    /// 다른 세션의 parent가 이 세션을 가리킬 때 쓰는 모양들.
    var parentKeys: Set<String> {
        var keys: Set<String> = [name, name + "@" + host]
        if let peerID { keys.insert(host + "/" + peerID) }
        return keys
    }
}

/// 오른쪽 노치가 쓰는 목록: 고른 워크스페이스에서 어느 패널에도 없는 세션(`sm ls --ws WS --background`, SEOL 11/15).
///
/// 세션의 소속은 세션 층이 워크스페이스 폴더로 정한다 — 패널이 없는 세션에는 탭이 없다. "패널에 없음"도 세션 층만
/// 안다. 한 번 읽는 데 0.5–2초가 들어(세션이 많은 워크스페이스는 2초) 고른 워크스페이스 하나만, 창이 보이는
/// 동안만 10초마다 뒤에서 읽는다. 그 사이의 상태(일하는 중·막힘)는 2초마다 오는 peer 목록으로 덧칠한다.
final class WorkspaceSessions: ObservableObject {
    static let shared = WorkspaceSessions()

    /// 배치 키("워크스페이스@기기") → 세션들.
    @Published private(set) var byLayout: [String: [WorkspaceSession]] = [:]

    static let interval: TimeInterval = 10

    private var wanted: [UUID: String] = [:]
    private var timer: Timer?
    private var inFlight = Set<String>()
    private let queue = DispatchQueue(label: "SpaceManager.WorkspaceSessions", qos: .utility)

    /// 이 창이 지금 보는 배치(없으면 nil). 아무 창도 원하지 않으면 멈춘다.
    func follow(_ key: String?, owner: UUID) {
        let before = wanted[owner]
        wanted[owner] = key
        if let key, key != before { refresh(key) }
        updateTimer()
    }

    func stop(owner: UUID) {
        wanted[owner] = nil
        updateTimer()
    }

    private func updateTimer() {
        if wanted.values.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer?.tolerance = 2
        }
    }

    private func tick() {
        // 숨겼거나 모든 창이 가려졌으면 읽지 않는다(다시 보이면 다음 차례에 읽는다).
        guard !NSApp.isHidden, NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) else { return }
        Set(wanted.values).forEach(refresh)
    }

    /// 지금 읽는다(창이 그 워크스페이스를 고른 순간, 배치가 바뀐 직후).
    func refresh(_ key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        queue.async { [weak self] in
            let sessions = Self.load(key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                guard let sessions, self.byLayout[key] != sessions else { return }
                self.byLayout[key] = sessions
            }
        }
    }

    /// 시험에서 세션 층 대신 목록을 넣는다(격리 홈에는 세션 층이 없다).
    func inject(_ sessions: [WorkspaceSession], for key: String) {
        byLayout[key] = sessions
    }

    /// nil이면 읽지 못했다(지난 목록을 그대로 둔다 — 아치가 잠깐 안 닿는다고 묶음이 깜빡이지 않게).
    static func load(_ key: String) -> [WorkspaceSession]? {
        guard case .success(let data) = SessionLayer.runSync(["ls", "--ws", key, "--background", "--json"]) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [WorkspaceSession]? {
        struct Listing: Decodable {
            struct Row: Decodable {
                struct Peer: Decodable { let id: String? }
                let name: String
                let host: String?
                let kind: String?
                let status: String?
                let state: String?
                let pane: String?
                let parent: String?
                let peer: Peer?
                let lastActive: Double?

                enum CodingKeys: String, CodingKey {
                    case name, host, kind, status, state, pane, parent, peer
                    case lastActive = "last_active"
                }
            }
            let sessions: [Row]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        return listing.sessions.map { row in
            WorkspaceSession(name: row.name, host: row.host ?? "", kind: row.kind ?? "", status: row.status ?? "",
                             state: row.state.flatMap(PeerState.init(rawValue:)) ?? .unknown, pane: row.pane,
                             parent: row.parent, peerID: row.peer?.id,
                             lastActive: row.lastActive.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

/// 오른쪽 노치에 오르는 에이전트 하나: 이 워크스페이스에서 돌지만 sm 패널에는 없는 것.
struct ShelfAgent: Identifiable, Equatable {
    let name: String
    let host: String
    /// claude | codex | omo …
    let kind: String
    let attention: AgentAttention
    let lastActive: Date?
    /// 띄운 에이전트의 이름(알면).
    let parent: String?

    var id: String { name + "@" + host }

    /// 도는 에이전트만(셸 제외). 띄운 쪽은 이름으로 보인다. 급한 것이 앞, 같으면 최근에 움직인 것이 앞.
    /// 상태는 peer 목록이 더 새것이면 그것으로.
    static func from(_ sessions: [WorkspaceSession], peers: PeerDirectory) -> [ShelfAgent] {
        var names: [String: String] = [:]
        for session in sessions { for key in session.parentKeys { names[key] = session.name } }
        for agent in peers.agents { names[agent.host + "/" + agent.id] = agent.name }
        return sessions
            .filter { $0.status == "running" && $0.pane == nil && $0.kind != "shell" && !$0.kind.isEmpty }
            .map { session -> ShelfAgent in
                let live = peers.agents.first { $0.name == session.name && $0.host == session.host && !$0.isStale }
                let parent = session.parent.map { names[$0] ?? $0.split(separator: "/").last.map(String.init) ?? $0 }
                return ShelfAgent(name: session.name, host: session.host, kind: session.kind,
                                  attention: live.map(peers.attention(of:)) ?? AgentAttention.of(state: session.state),
                                  lastActive: session.lastActive, parent: parent)
            }
            .sorted { lhs, rhs in
                lhs.attention != rhs.attention ? lhs.attention > rhs.attention
                    : (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
            }
    }
}
