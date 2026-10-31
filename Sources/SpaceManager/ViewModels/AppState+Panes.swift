import Foundation

/// 패널 분할과 이동. tmux의 prefix 키 대신 메뉴 단축키로 부른다.
extension AppState {
    /// 지금 탭의 포커스된 패널을 나눈다. 새 패널은 워크스페이스와 같은 폴더·실행 위치의 셸이다.
    ///
    /// 한계: 아직 셸만 연다. peer의 에이전트 holder가 나오면 새 패널이 `peer attach <id>`를
    /// 실행하도록 `make`만 바꾼다(cld-claude-7과 정한 "패널 = attach 명령 하나").
    func splitPane(_ axis: PaneAxis) {
        guard windowKind == .workspace, let tab = selectedSession, let workspace = selectedWorkspace else { return }
        panes.ensureGroup(for: tab).split(axis) { id in
            TerminalSession(id: id, kind: .shell,
                            name: TerminalSession.defaultShellName(remoteHost: workspace.remoteHost),
                            workingDirectory: workspace.rootPath,
                            remoteHost: workspace.remoteHost)
        }
    }

    /// peer가 아는 에이전트를 지금 탭의 새 패널로 연다. 이미 이 창의 패널에 붙어 있으면 그 패널로 간다.
    func openAgentInPane(_ agent: PeerAgent, axis: PaneAxis = .horizontal) {
        guard windowKind == .workspace, let tab = selectedSession, let workspace = selectedWorkspace else { return }
        for candidate in sessions {
            if let pane = paneSessions(of: candidate).first(where: {
                if case .agent(_, let host, let id) = $0.attachment { return id == agent.id && host == agent.host }
                return false
            }) {
                selectSession(candidate)
                panes.group(for: candidate)?.focus(pane.id)
                return
            }
        }
        panes.ensureGroup(for: tab).split(axis) { id in
            TerminalSession(id: id, kind: .shell, name: agent.name,
                            workingDirectory: workspace.rootPath,
                            attachment: .agent(name: agent.name, host: agent.host, agent: agent.id))
        }
    }

    var selectedPaneGroup: PaneGroup? {
        selectedSession.flatMap { panes.group(for: $0) }
    }

    func cyclePane(forward: Bool) {
        selectedPaneGroup?.cycleFocus(forward: forward)
    }

    func toggleZoomPane() {
        selectedPaneGroup?.toggleZoom()
    }

    func closeFocusedPane() {
        guard let group = selectedPaneGroup else { return }
        group.close(group.focused)
    }

    /// SEOL을 기다리는 다음 패널로 간다(막힘 > 오류 > 안 본 끝남, 같은 급이면 오래 기다린 순).
    /// 지금 창의 열린 탭과 그 패널 안에서만 찾는다 — 다른 워크스페이스의 탭은 사이드바 표시로 보인다.
    func focusNextWaitingPane(directory: PeerDirectory = .shared) {
        var candidates: [(tab: TerminalSession, pane: UUID, attention: AgentAttention, since: Date)] = []
        for tab in sessions {
            for pane in paneSessions(of: tab) {
                guard let agent = directory.agent(for: pane) else { continue }
                let attention = directory.attention(of: agent)
                if attention.needsSEOL { candidates.append((tab, pane.id, attention, agent.since)) }
            }
        }
        candidates.sort { lhs, rhs in
            lhs.attention != rhs.attention ? lhs.attention > rhs.attention : lhs.since < rhs.since
        }
        let current = selectedPaneGroup?.focused ?? selectedSession?.id
        // 지금 보고 있는 패널이 맨 앞이면 그다음으로 — 같은 키를 다시 누르면 다음 것으로 넘어간다.
        guard let target = candidates.first(where: { $0.pane != current }) ?? candidates.first else { return }
        selectSession(target.tab)
        panes.group(for: target.tab)?.focus(target.pane)
    }
}

extension PeerDirectory {
    /// 패널의 에이전트. holder에 붙은 패널은 peer 행 id로, sm이 직접 띄운 셸 속 에이전트는
    /// target(`sm:<패널 UUID>`)으로 찾는다.
    func agent(for session: TerminalSession, includeStale: Bool = false) -> PeerAgent? {
        if case .agent(_, let host, let id?) = session.attachment {
            return agents.first { (includeStale || !$0.isStale) && $0.id == id && $0.host == host }
        }
        return agent(forPane: session.id, includeStale: includeStale)
    }

    /// sm 패널(`sm:<패널 UUID>`)에서 도는 에이전트.
    /// 연결이 끊긴 기기의 지난 행(`isStale`)은 화면에는 남기되 건너뛰기 대상에서는 뺀다.
    func agent(forPane id: UUID, includeStale: Bool = false) -> PeerAgent? {
        let target = "sm:" + id.uuidString
        return agents.first {
            (includeStale || !$0.isStale) && $0.target.caseInsensitiveCompare(target) == .orderedSame
        }
    }
}

/// 사이드바에 올리는 묶음 상태 — 그 안의 에이전트 중 가장 급한 것 하나.
extension AppState {
    /// 탭 하나(나눈 패널 전부 포함)의 상태.
    func agentRollup(forTab tab: TerminalSession, directory: PeerDirectory) -> AgentAttention? {
        paneSessions(of: tab)
            .compactMap { directory.agent(for: $0, includeStale: true) }
            .map(directory.attention(of:))
            .max()
    }

    /// 탭의 패널들(나누지 않았으면 탭 자신).
    func paneSessions(of tab: TerminalSession) -> [TerminalSession] {
        guard let group = panes.group(for: tab) else { return [tab] }
        return group.paneIDs.compactMap(group.session(for:))
    }

    /// 워크스페이스의 상태. sm 패널의 에이전트와, 아직 tmux에 있는 에이전트(같은 기기·같은 세션 이름)를 함께 본다.
    ///
    /// tmux 매칭은 sm이 배치의 원본이 될 때까지의 다리다. holder로 옮기면 이 갈래를 지운다.
    func agentRollup(for workspace: Workspace, directory: PeerDirectory) -> AgentAttention? {
        let fromPanes = sessions(for: workspace).compactMap { agentRollup(forTab: $0, directory: directory) }
        let host = workspace.isRemote ? directory.peerHost(forAlias: workspace.remoteHost ?? "") : directory.localHostName
        let session = workspace.effectiveTmuxSessionName
        let fromTmux = directory.agents
            .filter { $0.host == host && $0.group == session && $0.target.hasPrefix("%") }
            .map(directory.attention(of:))
        return (fromPanes + fromTmux).max()
    }
}
