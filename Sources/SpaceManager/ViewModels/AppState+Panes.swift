import Foundation

/// 패널을 나누는 방향(⌘D 오른쪽, ⇧⌘D 아래).
enum PaneAxis: String, Codable {
    /// 좌우로 나란히
    case horizontal
    /// 위아래로 쌓기
    case vertical
}

/// 패널 분할과 이동. tmux의 prefix 키 대신 메뉴 단축키로 부른다.
extension AppState {
    /// 지금 탭의 포커스된 패널 옆에 자리를 만들고, 무엇을 열지 고르는 상자를 띄운다.
    /// tmux는 새 패널에 빈 명령줄을 띄웠지만, sm에서는 패널이 곧 에이전트다(SEOL 10/31).
    func splitPane(_ axis: PaneAxis) {
        guard let layout = selectedLayout else { return }
        beginLayoutSplit(axis, in: layout)
    }

    /// 세션 층이 쓰는 기기 이름(로컬이면 nil). 워크스페이스의 실행 위치는 ssh 별칭이라 peer 이름으로 되짚는다.
    func sessionHost(for workspace: Workspace) -> String? {
        guard workspace.isRemote, let alias = workspace.remoteHost else { return nil }
        return PeerDirectory.shared.peerHost(forAlias: alias)
    }

    /// 상자의 이름 기본값: 워크스페이스-엔진-번호. 지금 아는 세션·에이전트 이름과 겹치지 않는 가장 작은 번호.
    func suggestedAgentName(for engine: AgentEngine, taken: Set<String>) -> String {
        guard let workspace = selectedWorkspace else { return engine.rawValue }
        let base = workspace.effectiveLayoutName + "-" + engine.rawValue
        var n = 1
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// 지금 탭에 패널이 둘 이상인가(이동·확대 메뉴를 켤지).
    var hasMultiplePanes: Bool {
        guard let layout = selectedLayout, let tab = displayedTab(of: layout) else { return false }
        return tab.root.paneIDs.count > 1
    }

    /// 배치 탭에서 지금 포커스된 패널(방금 누른 것이 파일보다 앞선다).
    var focusedLayoutPane: String? {
        guard let workspace = selectedWorkspace, let layout = selectedLayout, let tab = displayedTab(of: layout) else { return nil }
        if let held = layoutInteraction.focusOverride, held.key == layoutKey(for: workspace),
           tab.root.paneIDs.contains(held.pane) { return held.pane }
        return tab.focus ?? tab.root.paneIDs.first
    }

    func cyclePane(forward: Bool) {
        guard let layout = selectedLayout, let ids = displayedTab(of: layout)?.root.paneIDs, ids.count > 1,
              let current = focusedLayoutPane, let index = ids.firstIndex(of: current) else { return }
        focusLayoutPane(ids[(index + (forward ? 1 : ids.count - 1)) % ids.count], in: layout)
    }

    func toggleZoomPane() {
        guard let layout = selectedLayout, let pane = focusedLayoutPane else { return }
        zoomLayoutPane(pane, in: layout)
    }

    func closeFocusedPane() {
        guard let layout = selectedLayout, let pane = focusedLayoutPane, hasMultiplePanes else { return }
        closeLayoutPane(pane, in: layout)
    }

    /// SEOL을 기다리는 다음 패널로 간다(막힘 > 오류, 같은 급이면 오래 기다린 순).
    func focusNextWaitingPane(directory: PeerDirectory = .shared) {
        guard let layout = selectedLayout, let workspace = selectedWorkspace else { return }
        focusNextWaitingLayoutPane(layout, workspace: workspace, directory: directory)
    }

    /// 워크스페이스 행의 상태 — 그 배치의 패널 에이전트 중 가장 급한 것 하나.
    func agentRollup(for workspace: Workspace, directory: PeerDirectory) -> AgentAttention? {
        guard let layout = layout(for: workspace) else { return nil }
        return layout.tabs.compactMap { layoutRollup(tab: $0, in: layout, directory: directory) }.max()
    }
}

extension Workspace {
    /// 원격 기기에서의 작업 폴더를 그쪽 세션 층이 펼칠 수 있는 모양으로(`~/…` 또는 절대 경로).
    var remoteDirectoryPath: String {
        switch remoteDirectory {
        case .relativeToHome(let relative): return relative.isEmpty ? "~" : "~/" + relative
        case .absolute(let path): return path
        }
    }
}
