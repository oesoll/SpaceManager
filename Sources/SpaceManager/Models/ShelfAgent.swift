import Foundation

/// 오른쪽 노치에 오르는 에이전트 하나: 이 워크스페이스에서 돌지만 sm 패널에는 없는 것(SEOL 11/15).
///
/// 이미 2초마다 받는 peer 목록과 이미 따라가는 배치 파일만으로 고른다 — 세션 층을 부르지 않는다. 처음에는
/// `sm ls --ws WS --background`를 10초마다(그리고 배치가 바뀔 때마다) 불렀는데, 한 번에 3초 가까이 걸리는 그 호출이
/// 맥 코어 하나의 절반을 상시로 먹었다(11/16 fine-13b7ee4d 실측). peer 행에 필요한 것이 다 있다: sm 세션인지
/// (hold), 작업 폴더, 띄운 쪽(parent), 상태.
///
/// 고르는 기준: 배치와 같은 기기의 sm 세션, 작업 폴더가 워크스페이스 폴더 아래, 끝나지 않음, 아는 어느 배치의
/// 패널에도 없음. 셸은 peer에 행이 없어 저절로 빠진다. 한계: 이 앱이 모르는 배치(보이지 않는 원격 워크스페이스)의
/// 패널에 있는 세션은 여기 오를 수 있다 — 거슬리면 세션 층의 "어느 패널에도 없음"을 상주 watch로 받는다.
struct ShelfAgent: Identifiable, Equatable {
    let name: String
    let host: String
    /// claude | codex | omo …
    let kind: String
    let attention: AgentAttention
    /// 지금 상태가 된 때.
    let lastActive: Date?
    /// 띄운 에이전트의 이름(알면).
    let parent: String?

    var id: String { name + "@" + host }

    static func from(layout: WorkspaceLayout, layouts: [WorkspaceLayout], peers: PeerDirectory) -> [ShelfAgent] {
        var shown = Set<String>()
        for each in layouts {
            for pane in each.panes.keys {
                if let agent = each.agent(inPane: pane) { shown.insert(agent.name + "@" + agent.host) }
            }
        }
        var names: [String: String] = [:]
        for agent in peers.agents { names[agent.host + "/" + agent.id] = agent.name }
        let folder = layout.cwd.hasSuffix("/") ? String(layout.cwd.dropLast()) : layout.cwd
        var latest: [String: PeerAgent] = [:]
        for agent in peers.agents where agent.host == layout.host && agent.hold != nil && !agent.isStale
            && agent.state != .gone && !shown.contains(agent.name + "@" + agent.host) {
            guard let cwd = agent.cwd, cwd == folder || cwd.hasPrefix(folder + "/") else { continue }
            if let other = latest[agent.name], other.since >= agent.since { continue }
            latest[agent.name] = agent
        }
        return latest.values
            .map { agent in
                ShelfAgent(name: agent.name, host: agent.host, kind: agent.kind, attention: peers.attention(of: agent),
                           lastActive: agent.since,
                           parent: agent.parent.map { names[$0] ?? $0.split(separator: "/").last.map(String.init) ?? $0 })
            }
            .sorted { lhs, rhs in
                lhs.attention != rhs.attention ? lhs.attention > rhs.attention
                    : (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
            }
    }
}
