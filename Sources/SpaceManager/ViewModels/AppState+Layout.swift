import AppKit
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

    /// 배치가 없는 워크스페이스에 배치를 만드는 중이거나 못 만든 것(키: 배치 키).
    enum Creation: Equatable { case inProgress, failed(String) }
    @Published var layoutCreation: [String: Creation] = [:]

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
        } else if let agent = pane?.agent(layoutHost: layout.host) {
            session = TerminalSession(name: agent.name, workingDirectory: workspace.rootPath,
                                      attachment: .agent(name: agent.name, host: agent.host, agent: nil))
        } else {
            // 세션이 없는 셸 패널. 원격 워크스페이스면 그 기기의 셸이다.
            session = TerminalSession(name: TerminalSession.defaultShellName(remoteHost: workspace.remoteHost),
                                      workingDirectory: workspace.rootPath, remoteHost: workspace.remoteHost)
        }
        session.layoutPane = (paneID, layout.workspace)
        sessions[key] = session
        return session
    }

    private static func matches(_ session: TerminalSession, pane: WorkspaceLayout.Pane?, host: String) -> Bool {
        switch session.attachment {
        case .agent(let name, let sessionHost, _):
            guard let agent = pane?.agent(layoutHost: host) else { return false }
            return agent.name == name && agent.host == sessionHost
        case .shell: return pane?.session == nil
        }
    }

    /// 어느 배치에도 없는 패널의 터미널을 닫는다(세션은 세션 층에서 계속 돈다).
    func prune(keeping live: Set<String>) {
        for (key, session) in sessions where !live.contains(key) {
            session.cleanup()
            sessions[key] = nil
            lastDisplayed[key] = nil
        }
    }

    /// 이 창에서 그 배치의 터미널을 닫는다(세션은 계속 돈다). 다른 창이 그 배치를 맡을 때 — 두 창이 같은 세션에
    /// 붙어 있으면 크기를 서로 바꾼다.
    func discard(layoutKey: String) {
        let prefix = layoutKey + "/"
        for (key, session) in sessions where key.hasPrefix(prefix) {
            session.cleanup()
            sessions[key] = nil
            lastDisplayed[key] = nil
        }
    }

    /// 세션 패널이 마지막으로 화면에 보인 때. 키는 `session(for:)`과 같은 "배치 키/패널".
    private var lastDisplayed: [String: Date] = [:]
    /// 지난번에 본 보이는 패널들. 여기서 빠지는 순간이 그 패널이 마지막으로 보인 때다.
    private var shown: Set<String> = []
    /// 가려진 세션 패널이 attach를 내리기까지. 세션 층은 보는 창이 하나도 없는 워크스페이스만 65분 쉰 뒤 재우므로
    /// (SEOL 11/01: "꺼지는 단위는 워크스페이스 단위로") 가려진 패널이 attach를 쥐고 있으면 아무것도 잠들지 못한다.
    /// 그렇다고 가려지자마자 내리면 탭·워크스페이스를 오갈 때마다 다시 붙느라 늦다(SEOL이 짚은 전환 지연).
    /// 10분이면 방금 본 탭은 바로 보이고, 잠들기(65분)는 막지 않는다.
    static let parkAfter: TimeInterval = 600

    /// 화면에 보이는 패널(`displayed`)은 시각을 적고, 가려진 지 `grace`가 지난 세션 패널은 attach를 내린다.
    /// 패널을 다시 보면 attach가 다시 뜨고, 세션 층이 잠든 세션을 깨우며 마지막 화면부터 보인다. 셸 패널은 내리면
    /// 그 셸이 끝나므로 두고, 세션 층의 세션을 보이는 패널만 내린다.
    func parkHidden(displayed: Set<String>, now: Date = Date(), grace: TimeInterval = LayoutTerminals.parkAfter) {
        note(displayed: displayed, now: now)
        let attached = Set(sessions.filter { _, session in
            if case .agent = session.attachment { return session.holdsAttach }
            return false
        }.keys)
        for key in Self.toPark(attached: attached, displayed: displayed, lastDisplayed: lastDisplayed, now: now, grace: grace) {
            sessions[key]?.park()
        }
    }

    /// 보이는 패널 중 내려 둔 세션 패널(무대가 쉬는 중)을 다시 붙인다.
    func resume(displayed: Set<String>, now: Date = Date()) {
        note(displayed: displayed, now: now)
        for key in displayed { sessions[key]?.resumeIfParked() }
    }

    /// 보이는 패널이 바뀔 때마다(탭·워크스페이스 전환, 창 가림, 1분 타이머) 적는다. 지금 보이는 패널과 방금 가려진
    /// 패널은 지금이 마지막으로 보인 때다. 1분 타이머에서만 적었더니, 다시 붙은 패널을 1분 안에 떠나면 그 방문이
    /// 적히지 않아 다음 타이머에 "10분 넘게 안 본 패널"로 내렸다 — 돌아오면 또 다시 붙었다(SEOL 11/09).
    func note(displayed: Set<String>, now: Date = Date()) {
        for key in shown.union(displayed) { lastDisplayed[key] = now }
        shown = displayed
    }

    func lastSeen(_ key: String) -> Date? { lastDisplayed[key] }

    /// 내릴 패널: attach가 붙은 세션 패널 가운데 지금 안 보이고, 마지막으로 보인 지 `grace`가 지난 것.
    static func toPark(attached: Set<String>, displayed: Set<String>, lastDisplayed: [String: Date],
                       now: Date, grace: TimeInterval) -> [String] {
        attached.subtracting(displayed).filter { now.timeIntervalSince(lastDisplayed[$0] ?? .distantPast) >= grace }.sorted()
    }

    var all: [TerminalSession] { Array(sessions.values) }
}

extension AppState {
    /// 이 워크스페이스의 배치 키("워크스페이스@기기"). 배치 이름은 tmux 세션 이름과 같다(옮겨 적을 때 그대로 썼다).
    func layoutKey(for workspace: Workspace) -> String {
        let host = sessionHost(for: workspace) ?? PeerDirectory.shared.localHostName
        return LayoutDirectory.key(workspace: workspace.effectiveLayoutName, host: host)
    }

    func layout(for workspace: Workspace, directory: LayoutDirectory = .shared) -> WorkspaceLayout? {
        directory.layouts[layoutKey(for: workspace)]
    }

    var selectedLayout: WorkspaceLayout? {
        selectedWorkspace.flatMap { layout(for: $0) }
    }

    /// 배치가 없는 워크스페이스에 셸 탭 하나짜리 배치를 만든다(`sm ws new NAME@HOST`). tmux 메인 탭이 하던
    /// 출발점이다. 사이드바 항목은 이미 있으니 세션 층이 앱에 알리지 않게(`--no-app`) 한다.
    /// 이미 있다는 답은 실패가 아니다 — 원격 watch가 4초 안에 첫 줄을 못 보낸 경우다. 곧 그 배치가 온다.
    func createLayout(for workspace: Workspace, retry: Bool = false) {
        let key = layoutKey(for: workspace)
        if let state = layoutInteraction.layoutCreation[key] {
            guard retry, case .failed = state else { return }
        }
        guard LayoutDirectory.shared.layouts[key] == nil else { return }
        layoutInteraction.layoutCreation[key] = .inProgress
        let host = sessionHost(for: workspace)
        let name = workspace.effectiveLayoutName + (host.map { "@" + $0 } ?? "")
        let cwd = workspace.isRemote ? workspace.remoteDirectoryPath : workspace.rootPath
        SessionLayer.run(["ws", "new", name, "--cwd", cwd, "--no-app", "--json"]) { result in
            if case .failure(let failure) = result, !failure.message.contains("workspace exists") {
                self.layoutInteraction.layoutCreation[key] = .failed(failure.message)
                return
            }
            LayoutDirectory.shared.reloadLocal()
        }
    }

    /// 파일이 따라잡은 임시 상태를 걷는다(포커스·탭).
    func settleLayoutOverrides(_ layout: WorkspaceLayout) {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        if layoutInteraction.layoutCreation[key] != nil { layoutInteraction.layoutCreation[key] = nil }
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

    /// 끌어 놓은 두 패널의 자리를 바꾼다. 바꾼 모양을 결과가 올 때까지 먼저 그린다(놓자마자 새 자리로 미끄러지게).
    func swapLayoutPanes(_ a: String, _ b: String, tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout) {
        guard a != b else { return }
        let root = tab.root.swappingPanes(a, b)
        layoutInteraction.rootOverride = (LayoutInteraction.tabKey(layout, tab.id), tab.id, root, layout.version + 1)
        runLayoutCommand(["swap", a, b], layout: layout) { result in
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
        runLayoutCommand(["tab", "new", "--focus", "--spawn", spec.name, "--kind", spec.engine.rawValue] + engineArgs, layout: layout) { result in
            self.finishNewTab(result, layout: layout, context: context)
        }
    }

    func bringIntoNewTab(_ session: AgentPickerSession, layout: WorkspaceLayout) {
        guard let context = layoutInteraction.pendingContext else { return }
        context.isLaunching = true
        context.error = nil
        runLayoutCommand(["tab", "new", "--focus", "--attach", session.name], layout: layout) { result in
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
    /// 패널의 세션을 Fine으로 옮긴다(SEOL 11/01: "에이전트를 sm에서 Fine으로, 역방향으로도"). Fine이 그 세션에
    /// 붙은 탭을 연 뒤에 이 패널을 닫는다 — 패널 닫기는 세션을 끝내지 않으므로 세션은 그대로 이어지고 보는
    /// 앱만 바뀐다. 탭의 마지막 패널이면 탭을 닫고, 워크스페이스의 마지막 탭이면 패널을 남겨 둔다.
    /// `completion`이 없으면(화면에서 누른 경우) 실패를 창으로 알린다. 있으면(`sm to-fine`) 실패 까닭을 넘긴다.
    func moveLayoutPaneToFine(_ pane: String, in layout: WorkspaceLayout, completion: ((String?) -> Void)? = nil) {
        guard let (name, host) = layout.agent(inPane: pane) else { completion?("pane \(pane) shows no session"); return }
        let target = host == PeerDirectory.shared.localHostName ? name : name + "@" + host
        MainActor.assumeIsolated {
            FineControl.attach(target) { [weak self] failure in
                guard let self else { return }
                if let failure {
                    if let completion { return completion(failure) }
                    let alert = NSAlert()
                    alert.messageText = "\(name)을 Fine으로 옮기지 못했습니다"
                    alert.informativeText = failure
                    alert.runModal()
                    return
                }
                defer { completion?(nil) }
                let current = LayoutDirectory.shared.layouts[LayoutDirectory.key(workspace: layout.workspace, host: layout.host)] ?? layout
                guard let tab = current.tab(containing: pane) else { return }
                if tab.root.paneIDs.count > 1 {
                    self.closeLayoutPane(pane, in: current)
                } else if current.tabs.count > 1 {
                    self.closeLayoutTab(tab.id, in: current)
                }
            }
        }
    }

    /// 탭 칩의 "Fine으로 옮기기": 패널이 하나뿐이고 그 패널이 세션을 보일 때.
    func movableToFine(tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout) -> String? {
        let panes = tab.root.paneIDs
        guard panes.count == 1, let pane = panes.first, let (name, host) = layout.agent(inPane: pane),
              // Fine 탭은 Claude·Codex만 보인다(셸 세션은 Fine이 받지 않는다).
              PeerDirectory.shared.agents.contains(where: { $0.name == name && $0.host == host }) else { return nil }
        return pane
    }

    func closeLayoutTab(_ tab: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "close", tab], layout: layout)
    }

    func renameLayoutTab(_ tab: String, to name: String, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "rename", tab, name], layout: layout)
    }

    func moveLayoutTab(_ tab: String, to index: Int, in layout: WorkspaceLayout) {
        runLayoutCommand(["tab", "move", tab, String(index)], layout: layout)
    }

    /// ⌘1…9, ⌥⌘←→: 배치의 탭을 오간다.
    func selectTab(at index: Int) {
        guard let layout = selectedLayout, layout.tabs.indices.contains(index) else { return }
        selectLayoutTab(layout.tabs[index].id, in: layout)
    }

    func stepTab(forward: Bool) {
        guard let layout = selectedLayout, !layout.tabs.isEmpty, let current = displayedTab(of: layout),
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
        let args = ["split", pending.beside, pending.dir == .row ? "--right" : "--down", "--focus",
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
        runLayoutCommand(["split", pending.beside, pending.dir == .row ? "--right" : "--down", "--focus", "--attach", session.name],
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
    /// 이 창이 지금 보여 주는 배치 패널(고른 워크스페이스의 앞에 나온 탭)의 키.
    /// 창이 화면에 실제로 보이지 않으면(sm을 숨김, 최소화, 다른 창에 완전히 가려짐) 아무것도 보이지 않는 것이다.
    func displayedLayoutPanes(directory: LayoutDirectory = .shared, window: NSWindow? = nil) -> Set<String> {
        if let window, !window.occlusionState.contains(.visible) { return [] }
        guard let workspace = selectedWorkspace,
              let layout = layout(for: workspace, directory: directory), let tab = displayedTab(of: layout) else { return [] }
        let prefix = LayoutDirectory.key(workspace: layout.workspace, host: layout.host) + "/"
        return Set(tab.root.paneIDs.map { prefix + $0 })
    }

    func parkHiddenLayoutTerminals() {
        let displayed = displayedLayoutPanes(window: ownWindow)
        layoutTerminals.parkHidden(displayed: displayed)
        layoutTerminals.resume(displayed: displayed)
    }

    /// 창이 다시 보였다(앞으로 나옴, 가림이 걷힘, sm 보이기): 내려 둔 세션 패널을 다시 붙인다. 화면 갱신(탭·워크스페이스
    /// 고르기)만 기다리면 얼린 화면이 그대로 남고 입력이 무대에 붙잡힌 채 어디에도 가지 않았다(11/01).
    func resumeDisplayedLayoutTerminals() {
        layoutTerminals.resume(displayed: displayedLayoutPanes(window: ownWindow))
    }

    private var ownWindow: NSWindow? {
        WorkspaceWindowRegistry.shared.liveEntries().first { $0.state === self }?.window
    }

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
            .compactMap(layout.agent(inPane:))
            .compactMap { pane in directory.agents.first { $0.name == pane.name && $0.host == pane.host } }
            .map(directory.attention(of:))
            .max()
    }

    /// 배치 탭 하나의 노치 알림들.
    func layoutNotices(tab: WorkspaceLayout.Tab, in layout: WorkspaceLayout, directory: PeerDirectory) -> [AttentionItem] {
        tab.root.paneIDs
            .compactMap(layout.agent(inPane:))
            .compactMap { pane in directory.agents.first { $0.name == pane.name && $0.host == pane.host } }
            .compactMap(directory.notice(for:))
    }

    /// ⌘J: 이 워크스페이스의 모든 탭에서 SEOL을 기다리는 패널로(막힘 > 오류 > 안 본 끝남, 오래 기다린 순).
    func focusNextWaitingLayoutPane(_ layout: WorkspaceLayout, workspace: Workspace, directory: PeerDirectory) {
        var candidates: [(tab: String, pane: String, attention: AgentAttention, since: Date)] = []
        for tab in layout.tabs {
            for pane in tab.root.paneIDs {
                guard let (name, host) = layout.agent(inPane: pane),
                      let agent = directory.agents.first(where: { $0.name == name && $0.host == host }) else { continue }
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
