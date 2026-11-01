import Foundation

/// 배치 데이터(`WorkspaceLayout`)가 있는 워크스페이스를 그리고 바꾸는 쪽.
///
/// 원본은 세션 층의 파일이고 앱은 그것을 그린다. 바꿀 때는 언제나 `sm-session` 명령을 부른다 —
/// 에이전트가 `sm split`으로 바꾼 것과 SEOL이 화면에서 바꾼 것이 같은 길로 같은 파일에 쌓인다.
/// 화면은 명령의 결과를 기다리지 않는다. 클릭·끌기는 즉시 보이고(아래 `LayoutInteraction`),
/// 파일의 새 version이 오면 그것으로 갈아 끼운다.
final class LayoutInteraction: ObservableObject {
    /// 고르는 상자를 띄운, 아직 데이터에 없는 자리.
    struct Pending: Equatable {
        let workspaceKey: String
        let tabID: String
        let beside: String
        let dir: LayoutNode.Direction
        let paneID: String
        static func == (lhs: Pending, rhs: Pending) -> Bool { lhs.paneID == rhs.paneID }
    }

    @Published var pending: Pending?
    /// 새 탭을 고르는 중인 워크스페이스(키). 탭 전체가 고르는 상자가 된다.
    @Published var pendingTab: String?
    var pendingContext: AgentPickerContext?
    /// 방금 누른 패널. 명령이 파일에 닿기 전까지 이것을 포커스로 그린다.
    @Published var focusOverride: (key: String, pane: String)?
    /// 방금 고른 탭. 마찬가지로 파일이 따라잡을 때까지.
    @Published var activeTabOverride: (key: String, tab: String)?
    /// 명령을 보낸 뒤 그 결과(version)가 오기 전까지 이 탭을 이 모양으로 그린다(끌기를 놓은 직후 등).
    @Published var rootOverride: (key: String, tab: String, root: LayoutNode, until: Int)?

    static func tabKey(_ layout: WorkspaceLayout, _ tab: String) -> String {
        LayoutDirectory.key(workspace: layout.workspace, host: layout.host) + "/" + tab
    }
}

/// 배치 패널의 터미널. 패널 id마다 하나 — 탭을 오가도 다시 붙지 않는다.
final class LayoutTerminals {
    private var sessions: [String: TerminalSession] = [:]
    /// 시험에서 터미널을 바꿔 끼우는 자리(세션 층 없이 화면을 찍을 때).
    var makeSession: ((String, WorkspaceLayout.Pane?, WorkspaceLayout, Workspace) -> TerminalSession)?

    func session(for paneID: String, in layout: WorkspaceLayout, workspace: Workspace) -> TerminalSession {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host) + "/" + paneID
        let pane = layout.panes[paneID]
        if let existing = sessions[key], makeSession != nil || Self.matches(existing, pane: pane, host: layout.host) { return existing }
        sessions[key]?.cleanup()
        let session: TerminalSession
        if let make = makeSession {
            session = make(paneID, pane, layout, workspace)
        } else if let name = pane?.session {
            session = TerminalSession(kind: .shell, name: name, workingDirectory: workspace.rootPath,
                                      attachment: .agent(name: name, host: layout.host, agent: nil))
        } else {
            // 세션이 없는 셸 패널. 원격 워크스페이스면 그 기기의 셸이다.
            session = TerminalSession(kind: .shell, name: TerminalSession.defaultShellName(remoteHost: workspace.remoteHost),
                                      workingDirectory: workspace.rootPath, remoteHost: workspace.remoteHost)
        }
        session.layoutPane = (paneID, layout.workspace)
        sessions[key] = session
        return session
    }

    private static func matches(_ session: TerminalSession, pane: WorkspaceLayout.Pane?, host: String) -> Bool {
        switch session.attachment {
        case .agent(let name, let sessionHost, _): return pane?.session == name && sessionHost == host
        case .shell: return pane?.session == nil
        }
    }

    /// 어느 배치에도 없는 패널의 터미널을 닫는다(세션은 세션 층에서 계속 돈다).
    func prune(keeping live: Set<String>) {
        for (key, session) in sessions where !live.contains(key) {
            session.cleanup()
            sessions[key] = nil
        }
    }

    var all: [TerminalSession] { Array(sessions.values) }
}

extension AppState {
    /// 이 워크스페이스의 배치 키("워크스페이스@기기"). 배치 이름은 tmux 세션 이름과 같다(옮겨 적을 때 그대로 썼다).
    func layoutKey(for workspace: Workspace) -> String {
        let host = sessionHost(for: workspace) ?? PeerDirectory.shared.localHostName
        return LayoutDirectory.key(workspace: workspace.effectiveTmuxSessionName, host: host)
    }

    func layout(for workspace: Workspace, directory: LayoutDirectory = .shared) -> WorkspaceLayout? {
        directory.layouts[layoutKey(for: workspace)]
    }

    var selectedLayout: WorkspaceLayout? {
        selectedWorkspace.flatMap { layout(for: $0) }
    }

    /// 파일이 따라잡은 임시 상태를 걷는다(포커스·탭).
    func settleLayoutOverrides(_ layout: WorkspaceLayout) {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        if let held = layoutInteraction.focusOverride, held.key == key, layout.tab(containing: held.pane)?.focus == held.pane {
            layoutInteraction.focusOverride = nil
        }
        if let held = layoutInteraction.activeTabOverride, held.key == key, layout.activeTab == held.tab {
            layoutInteraction.activeTabOverride = nil
        }
    }

    /// 배치 명령 하나. 워크스페이스는 언제나 `--ws WS@HOST`로 못 박는다(원격이면 세션 층이 ssh로 간다).
    func runLayoutCommand(_ arguments: [String], layout: WorkspaceLayout,
                          completion: ((Result<Data, SessionLayer.Failure>) -> Void)? = nil) {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        SessionLayer.run(arguments + ["--ws", key, "--json"]) { result in
            if case .failure(let failure) = result {
                NSLog("sm-session %@ failed: %@", arguments.joined(separator: " "), failure.message)
            }
            LayoutDirectory.shared.reloadLocal()
            completion?(result)
        }
    }

    // MARK: - 화면에서 바꾸기

    func focusLayoutPane(_ pane: String, in layout: WorkspaceLayout) {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        layoutInteraction.focusOverride = (key, pane)
        if let tab = layout.tab(containing: pane), tab.id != displayedTab(of: layout)?.id {
            layoutInteraction.activeTabOverride = (key, tab.id)
        }
        runLayoutCommand(["focus", pane], layout: layout)
    }

    func selectLayoutTab(_ tab: String, in layout: WorkspaceLayout) {
        layoutInteraction.activeTabOverride = (LayoutDirectory.key(workspace: layout.workspace, host: layout.host), tab)
        runLayoutCommand(["tab", "select", tab], layout: layout)
    }

    /// 화면에 그릴 탭: 방금 고른 탭이 파일보다 앞선다.
    func displayedTab(of layout: WorkspaceLayout) -> WorkspaceLayout.Tab? {
        if let held = layoutInteraction.activeTabOverride,
           held.key == LayoutDirectory.key(workspace: layout.workspace, host: layout.host),
           let tab = layout.tabs.first(where: { $0.id == held.tab }) {
            return tab
        }
        return layout.currentTab
    }

    func zoomLayoutPane(_ pane: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["zoom", pane], layout: layout)
    }

    /// 패널을 닫는다. 그 세션은 뒤에서 계속 돈다(상자의 "가져오기"로 되돌릴 수 있다).
    func closeLayoutPane(_ pane: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["close", pane], layout: layout)
    }

    /// 경계선을 놓았다. 끄는 동안 본 모양을 결과가 올 때까지 그대로 두고, 몫은 명령으로 쓴다.
    /// `--toward`로 그 선 양쪽 두 칸만 바뀐다(tmux와 같다). 화면 미리보기와 결과가 같아 놓을 때 튀지 않는다.
    func commitResize(_ boundary: LayoutBoundary, sizes: [Double], tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout) {
        let total = sizes.reduce(0, +)
        guard total > 0, let branch = tab.root.child(at: boundary.path),
              case .split(_, let children, _) = branch else { return }
        let flag = boundary.dir == .row ? "--width" : "--height"
        let args: [String]
        if let pane = children[boundary.index].resizeTarget(crossing: boundary.dir) {
            args = ["resize", pane, flag, String(format: "%.4f", sizes[boundary.index] / total), "--toward", "next"]
        } else if let pane = children[boundary.index + 1].resizeTarget(crossing: boundary.dir) {
            args = ["resize", pane, flag, String(format: "%.4f", sizes[boundary.index + 1] / total), "--toward", "prev"]
        } else {
            return
        }
        let root = tab.root.resizing(path: boundary.path, sizes: sizes)
        layoutInteraction.rootOverride = (LayoutInteraction.tabKey(layout, tab.id), tab.id, root, layout.version + 1)
        runLayoutCommand(args, layout: layout) { result in
            if case .failure = result { self.layoutInteraction.rootOverride = nil }
        }
    }

    /// tmux에 남은 에이전트를 같은 대화 그대로 sm 세션으로(세션 층의 migrate). 배치는 세션 층이 고친다.
    func migrateToSessionLayer(_ name: String, host: String) {
        SessionLayer.run(["migrate", name + "@" + host, "--json"]) { result in
            if case .failure(let failure) = result { NSLog("sm-session migrate %@ failed: %@", name, failure.message) }
            LayoutDirectory.shared.reloadLocal()
        }
    }

    // MARK: - 새 자리(고르는 상자)

    /// ⌘D: 포커스된 패널 옆에 자리를 만들고 상자를 띄운다. 고르기 전에는 데이터에 쓰지 않는다.
    func beginLayoutSplit(_ axis: PaneAxis, in layout: WorkspaceLayout) {
        guard let workspace = selectedWorkspace, let tab = displayedTab(of: layout) else { return }
        let target = layoutInteraction.focusOverride.flatMap { tab.root.paneIDs.contains($0.pane) ? $0.pane : nil }
            ?? tab.focus ?? tab.root.paneIDs.first
        guard let target else { return }
        let context = AgentPickerContext(claudeModels: AgentModelCatalog.claudeFallback(), codexModels: AgentModelCatalog.codex())
        layoutInteraction.pendingContext = context
        layoutInteraction.pending = .init(workspaceKey: LayoutDirectory.key(workspace: layout.workspace, host: layout.host),
                                          tabID: tab.id, beside: target, dir: axis == .horizontal ? .row : .col,
                                          paneID: "pending-" + UUID().uuidString)
        let host = sessionHost(for: workspace)
        let workspaceName = layout.workspace
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = AgentModelCatalog.claude()
            let sessions = SessionLayer.backgroundSessions(workspace: workspaceName, host: host)
            DispatchQueue.main.async {
                if !claude.isEmpty { context.claudeModels = claude }
                context.backgroundSessions = sessions
            }
        }
    }

    func cancelLayoutSplit() {
        layoutInteraction.pending = nil
        layoutInteraction.pendingTab = nil
        layoutInteraction.pendingContext = nil
    }

    // MARK: - 탭

    /// 새 탭(+ / ⌘T): 탭 자리를 만들고 고르는 상자를 띄운다. 고르기 전에는 데이터에 쓰지 않는다.
    func beginLayoutNewTab(in layout: WorkspaceLayout) {
        guard let workspace = selectedWorkspace else { return }
        layoutInteraction.pending = nil
        let context = AgentPickerContext(claudeModels: AgentModelCatalog.claudeFallback(), codexModels: AgentModelCatalog.codex())
        layoutInteraction.pendingContext = context
        layoutInteraction.pendingTab = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        loadPickerLists(context, workspace: layout.workspace, host: sessionHost(for: workspace))
    }

    private func loadPickerLists(_ context: AgentPickerContext, workspace: String, host: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = AgentModelCatalog.claude()
            let sessions = SessionLayer.backgroundSessions(workspace: workspace, host: host)
            DispatchQueue.main.async {
                if !claude.isEmpty { context.claudeModels = claude }
                context.backgroundSessions = sessions
            }
        }
    }

    /// 새 탭 상자에서 "열기": 탭과 에이전트를 한 번에(`tab new --spawn`). 실패하면 세션 층이 탭도 지운다.
    func launchInNewTab(_ spec: AgentLaunchSpec, layout: WorkspaceLayout) {
        guard let context = layoutInteraction.pendingContext else { return }
        context.isLaunching = true
        context.error = nil
        AgentPickerDefaults(engine: spec.engine, modelID: spec.modelID, effort: spec.effort).save()
        let engineArgs = Array(SessionLayer.spawnArguments(spec, pane: nil, workingDirectory: layout.cwd).drop(while: { $0 != "--" }))
        runLayoutCommand(["tab", "new", "--spawn", spec.name, "--kind", spec.engine.rawValue] + engineArgs, layout: layout) { result in
            self.finishNewTab(result, layout: layout, context: context)
        }
    }

    func bringIntoNewTab(_ session: AgentPickerSession, layout: WorkspaceLayout) {
        guard let context = layoutInteraction.pendingContext else { return }
        context.isLaunching = true
        context.error = nil
        runLayoutCommand(["tab", "new", "--attach", session.name], layout: layout) { result in
            self.finishNewTab(result, layout: layout, context: context)
        }
    }

    private func finishNewTab(_ result: Result<Data, SessionLayer.Failure>, layout: WorkspaceLayout, context: AgentPickerContext) {
        switch result {
        case .success(let data):
            struct Reply: Decodable { let tab: String }
            if let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                layoutInteraction.activeTabOverride = (LayoutDirectory.key(workspace: layout.workspace, host: layout.host), reply.tab)
            }
            cancelLayoutSplit()
        case .failure(let failure):
            context.isLaunching = false
            context.error = failure.message
        }
    }

    /// 탭을 닫는다. 그 안의 세션들은 뒤에서 계속 돈다.
    func closeLayoutTab(_ tab: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "close", tab], layout: layout)
    }

    func renameLayoutTab(_ tab: String, to name: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "rename", tab, name], layout: layout)
    }

    func moveLayoutTab(_ tab: String, to index: Int, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "move", tab, String(index)], layout: layout)
    }

    /// ⌘1…9, ⌥⌘←→. 배치가 있으면 배치의 탭을, 없으면 지금까지의 탭을 오간다.
    func selectTab(at index: Int) {
        if let layout = selectedLayout {
            guard layout.tabs.indices.contains(index) else { return }
            selectLayoutTab(layout.tabs[index].id, in: layout)
        } else if sessions.indices.contains(index) {
            selectSession(sessions[index])
        }
    }

    func stepTab(forward: Bool) {
        guard let layout = selectedLayout else {
            forward ? selectNextSession() : selectPreviousSession()
            return
        }
        guard !layout.tabs.isEmpty, let current = displayedTab(of: layout),
              let index = layout.tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (index + (forward ? 1 : layout.tabs.count - 1)) % layout.tabs.count
        selectLayoutTab(layout.tabs[next].id, in: layout)
    }

    /// 상자에서 "열기": 그 자리에 에이전트를 띄우는 split 하나. 세션 층이 배치와 세션을 함께 만든다.
    func launchInLayout(_ spec: AgentLaunchSpec, layout: WorkspaceLayout) {
        guard let pending = layoutInteraction.pending, let context = layoutInteraction.pendingContext else { return }
        context.isLaunching = true
        context.error = nil
        AgentPickerDefaults(engine: spec.engine, modelID: spec.modelID, effort: spec.effort).save()
        let spawn = SessionLayer.spawnArguments(spec, pane: nil, workingDirectory: layout.cwd)
        let engineArgs = Array(spawn.drop(while: { $0 != "--" }))
        let args = ["split", pending.beside, pending.dir == .row ? "--right" : "--down",
                    "--spawn", spec.name, "--kind", spec.engine.rawValue]
        runLayoutCommand(args + engineArgs, layout: layout) { result in
            self.finishPending(result, context: context)
        }
    }

    /// 상자에서 "가져오기": 뒤에서 돌던(또는 끝난) 세션을 그 자리로. 끝난 세션은 세션 층이 되살린다.
    func bringIntoLayout(_ session: AgentPickerSession, layout: WorkspaceLayout) {
        guard let pending = layoutInteraction.pending, let context = layoutInteraction.pendingContext else { return }
        context.isLaunching = true
        context.error = nil
        runLayoutCommand(["split", pending.beside, pending.dir == .row ? "--right" : "--down", "--attach", session.name],
                         layout: layout) { result in
            self.finishPending(result, context: context)
        }
    }

    private func finishPending(_ result: Result<Data, SessionLayer.Failure>, context: AgentPickerContext) {
        switch result {
        case .success(let data):
            // 새 패널에 포커스를 둔다.
            if let reply = try? JSONDecoder().decode(SplitReply.self, from: data),
               let key = layoutInteraction.pending?.workspaceKey {
                layoutInteraction.focusOverride = (key, reply.pane)
            }
            layoutInteraction.pending = nil
            layoutInteraction.pendingContext = nil
        case .failure(let failure):
            context.isLaunching = false
            context.error = failure.message
        }
    }

    private struct SplitReply: Decodable {
        let pane: String
    }

    /// 배치에 있는 모든 패널의 터미널만 남긴다.
    func pruneLayoutTerminals(directory: LayoutDirectory = .shared) {
        var live = Set<String>()
        for layout in directory.layouts.values {
            let prefix = LayoutDirectory.key(workspace: layout.workspace, host: layout.host) + "/"
            for tab in layout.tabs { for pane in tab.root.paneIDs { live.insert(prefix + pane) } }
        }
        layoutTerminals.prune(keeping: live)
    }
}


extension AppState {
    /// 배치 탭 하나의 묶음 상태 — 그 안 패널 세션들 중 가장 급한 것.
    func layoutRollup(tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout, directory: PeerDirectory) -> AgentAttention? {
        tab.root.paneIDs
            .compactMap { layout.panes[$0]?.session }
            .compactMap { name in directory.agents.first { $0.name == name && $0.host == layout.host } }
            .map(directory.attention(of:))
            .max()
    }

    /// 배치 탭 하나의 노치 알림들.
    func layoutNotices(tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout, directory: PeerDirectory) -> [NotchNotice] {
        tab.root.paneIDs
            .compactMap { layout.panes[$0]?.session }
            .compactMap { name in directory.agents.first { $0.name == name && $0.host == layout.host } }
            .compactMap(directory.notice(for:))
    }

    /// ⌘J: 이 워크스페이스의 모든 탭에서 SEOL을 기다리는 패널로(막힘 > 오류 > 안 본 끝남, 오래 기다린 순).
    func focusNextWaitingLayoutPane(_ layout: WorkspaceLayout, workspace: Workspace, directory: PeerDirectory) {
        var candidates: [(tab: String, pane: String, attention: AgentAttention, since: Date)] = []
        for tab in layout.tabs {
            for pane in tab.root.paneIDs {
                guard let name = layout.panes[pane]?.session,
                      let agent = directory.agents.first(where: { $0.name == name && $0.host == layout.host }) else { continue }
                let attention = directory.attention(of: agent)
                if attention.needsSEOL { candidates.append((tab.id, pane, attention, agent.since)) }
            }
        }
        candidates.sort { $0.attention != $1.attention ? $0.attention > $1.attention : $0.since < $1.since }
        let current = focusedLayoutPane
        guard let target = candidates.first(where: { $0.pane != current }) ?? candidates.first else { return }
        // focus는 그 패널의 탭도 함께 앞으로 꺼낸다(세션 층의 focus가 active_tab을 바꾼다).
        focusLayoutPane(target.pane, in: layout)
    }
}
