import SwiftUI

/// 터미널 카드의 내용. 나누지 않은 탭은 지금처럼 터미널 하나를 그리고, 나눈 탭은 패널 분할을 그린다.
/// 이 창이 떠 있는 동안 peer 목록을 받아 패널 이름 줄에 에이전트 상태를 붙인다.
struct TabSurfaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabSurfaceContent(panes: appState.panes, directory: .shared, layouts: .shared,
                          interaction: appState.layoutInteraction)
    }
}

private struct TabSurfaceContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var panes: PaneStore
    @ObservedObject var directory: PeerDirectory
    @ObservedObject var layouts: LayoutDirectory
    @ObservedObject var interaction: LayoutInteraction
    /// 이 창에서 지금 워크스페이스의, 한 번이라도 보인 탭.
    @State private var visited: (key: String, tabs: Set<String>) = ("", [])
    /// 바로 전에 보이던 탭·워크스페이스의 자리. 새로 들어오는 화면이 어느 쪽에서 오는지 정한다.
    @State private var lastTab: (key: String, index: Int) = ("", 0)
    @State private var lastWorkspaceIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 탭·워크스페이스 전환(SEOL 10/31 "스페이스, 탭 전환 애니메이션"). 탭 막대는 가로라 탭은 옆에서,
    /// 사이드바는 세로라 워크스페이스는 위아래에서 들어온다 — 누른 것이 놓인 쪽에서 화면이 온다.
    /// 짧게 밀리며 겹쳐 흐려진다. 튀지 않는 스프링이고, 키 입력은 누른 순간 새 화면으로 간다.
    static let switchSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)
    static let tabSlide: CGFloat = 36
    static let workspaceSlide: CGFloat = 28
    /// 동작 줄이기: 움직이지 않고 겹쳐 바뀌기만 한다.
    private var switchAnimation: Animation { reduceMotion ? .easeOut(duration: 0.15) : Self.switchSpring }
    /// 떠나는 화면은 빨리 흐려진다. 같은 속도로 겹쳐 흐려지면 터미널 글자 두 벌이 반투명하게 겹쳐 보였다
    /// (10/31 전환 도중 캡처). 들어오는 쪽에는 지연을 두지 않는다.
    static let leaving = Animation.easeOut(duration: 0.1)

    private func remember(_ tab: String, in layoutKey: String) {
        if visited.key != layoutKey { visited = (layoutKey, [tab]) } else if !visited.tabs.contains(tab) { visited.tabs.insert(tab) }
    }

    /// 배치 데이터가 있는 워크스페이스면 그것을 그린다(tmux 탭 없이).
    private var layoutTab: (WorkspaceLayout, WorkspaceLayout.Tab, Workspace)? {
        guard appState.windowKind == .workspace, let workspace = appState.selectedWorkspace,
              let layout = layouts.layouts[appState.layoutKey(for: workspace)], let tab = appState.displayedTab(of: layout) else { return nil }
        return (layout, tab, workspace)
    }

    /// 이 워크스페이스에 배치가 있는지 아직 모른다 — 빈 카드로 기다린다(옛 탭을 먼저 붙이지 않는다).
    private var layoutUndecided: Bool {
        guard appState.windowKind == .workspace, let workspace = appState.selectedWorkspace else { return false }
        return !layouts.isSettled(appState.layoutKey(for: workspace), remote: workspace.isRemote)
    }

    /// 이 창이 따라갈 원격 배치(선택된 원격 워크스페이스 하나).
    private var remoteLayoutKeys: Set<String> {
        guard appState.windowKind == .workspace, let workspace = appState.selectedWorkspace, workspace.isRemote else { return [] }
        return [appState.layoutKey(for: workspace)]
    }

    private var group: PaneGroup? {
        guard appState.windowKind == .workspace, let tab = appState.selectedSession,
              let group = panes.group(for: tab), group.isSplit else { return nil }
        return group
    }

    private var workspaceIndex: Int {
        appState.workspaces.firstIndex { $0.id == appState.selectedWorkspace?.id } ?? 0
    }

    var body: some View {
        Group {
            if layoutUndecided {
                Color(Chrome.pane)
                    .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous)
                        .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
                    .transition(.identity)
            } else if let layout = layoutTab?.0, interaction.pendingTab == LayoutDirectory.key(workspace: layout.workspace, host: layout.host) {
                // 새 탭: 탭 전체가 고르는 상자 하나다.
                PickerCardStandalone { newTabPicker(layout: layout) }
                    .transition(.identity)
            } else if let (layout, tab, workspace) = layoutTab {
                // 한 번 본 탭은 떼지 않고 겹쳐 둔다. 탭마다 새로 지으면 전환할 때마다 메인 스레드가 40–70ms
                // 멈추고(프레임 2–4장), 다시 붙은 터미널이 첫 장면을 그리기 전까지 빈 카드가 비쳤다(10/31
                // `sm perf`·`sm capture --burst` 실측). 겹쳐 두면 전환은 보이기만 바꾸는 일이다. 숨은 탭의
                // 터미널은 그리지 않으므로(occlusion) GPU는 보이는 탭 몫만 쓴다. 워크스페이스를 바꾸면 비운다
                // — 여러 워크스페이스의 탭을 다 들고 있으면 돌아올 때 한꺼번에 지어 오히려 느리다.
                let layoutKey = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
                let mounted = visited.key == layoutKey ? visited.tabs : []
                let order = layout.tabs.map(\.id)
                let shownIndex = order.firstIndex(of: tab.id) ?? 0
                // 처음 보는 탭은 지금 막 생겨나므로, 전에 보던 탭과의 자리로 들어올 쪽을 정한다.
                let entering = CGFloat(lastTab.key == layoutKey ? (shownIndex - lastTab.index).signum() : 0)
                ZStack {
                    ForEach(layout.tabs.filter { $0.id == tab.id || mounted.contains($0.id) }) { each in
                        let shown = each.id == tab.id
                        // 숨은 탭은 탭 막대에서 놓인 쪽(지금 탭의 오른쪽이면 오른쪽)으로 살짝 비켜 있다. 고르면 그
                        // 자리에서 가운데로 들어오고, 떠나는 탭은 반대쪽으로 밀리며 흐려진다.
                        let side = CGFloat(((order.firstIndex(of: each.id) ?? 0) - shownIndex).signum())
                        LayoutTabView(layout: layout, tab: each, workspace: workspace, interaction: interaction,
                                      directory: directory, picker: { pending in
                            AnyView(layoutPicker(pending, layout: layout))
                        }, isShown: shown)
                        .offset(x: shown || reduceMotion ? 0 : side * Self.tabSlide)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                        .zIndex(shown ? 1 : 0)
                        .animation(shown ? switchAnimation : Self.leaving, value: tab.id)
                        .transition(reduceMotion ? .opacity : .offset(x: entering * Self.tabSlide).combined(with: .opacity))
                    }
                }
                .id(layoutKey)
                // 워크스페이스를 바꾸면 사이드바에서 놓인 쪽(아래면 아래)에서 올라온다. 떠나는 쪽은 제자리에서 흐려진다
                // — 떠나는 화면의 방향은 그 화면이 마지막으로 그려질 때 정해져 있어 이번 방향을 알 수 없다.
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity
                        : .offset(y: (workspaceIndex >= lastWorkspaceIndex ? 1 : -1) * Self.workspaceSlide).combined(with: .opacity),
                    removal: .opacity.animation(Self.leaving)))
                .onAppear {
                    remember(tab.id, in: layoutKey)
                    lastTab = (layoutKey, shownIndex)
                }
                .onChange(of: LayoutInteraction.tabKey(layout, tab.id)) { _, _ in
                    remember(tab.id, in: layoutKey)
                    lastTab = (layoutKey, shownIndex)
                }
            } else if let group {
                // 옛 tmux 탭 화면은 움직이지 않는다 — 떠나는 화면과 들어오는 화면이 같은 터미널을 두고 다툰다.
                SplitTab(group: group, directory: directory)
                    .transition(.identity)
            } else if appState.windowKind == .workspace {
                // 작업 창은 카드 라운딩이 없어 글자가 세로선에 붙는다. 셀 한 칸 남짓 들인다.
                SingleTerminalView()
                    .padding(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 4))
                    // 카드가 팔레트와 같은 색을 깔아 터미널 둘레 여백도 같은 면으로 읽힌다.
                    .background(Color(Chrome.pane))
                    .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous)
                        .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
                    .transition(.identity)
            } else {
                SingleTerminalView()
                    .background(Color(nsColor: GlassSurfacePolicy.terminalCardColor(for: appState.windowKind)))
                    .transition(.identity)
            }
        }
        .animation(switchAnimation, value: appState.selectedWorkspace?.id)
        .onChange(of: appState.selectedWorkspace?.id) { _, _ in lastWorkspaceIndex = workspaceIndex }
        .onAppear {
            guard appState.windowKind == .workspace else { return }
            directory.start(owner: appState.windowStateId)
            layouts.start(owner: appState.windowStateId)
            layouts.setRemote(remoteLayoutKeys, owner: appState.windowStateId)
        }
        .onDisappear {
            guard appState.windowKind == .workspace else { return }
            directory.stop(owner: appState.windowStateId)
            layouts.stop(owner: appState.windowStateId)
        }
        .onChange(of: remoteLayoutKeys) { _, keys in
            layouts.setRemote(keys, owner: appState.windowStateId)
        }
        .onChange(of: layouts.layouts) { _, _ in
            appState.pruneLayoutTerminals()
            // 파일이 따라잡았으면 화면 쪽 임시 상태를 걷는다.
            if let layout = layoutTab?.0 { appState.settleLayoutOverrides(layout) }
            closeLegacyTerminalsIfLayoutShown()
        }
        .onChange(of: appState.selectedWorkspace?.id) { _, _ in
            closeLegacyTerminalsIfLayoutShown()
        }
        .onChange(of: viewingKey) { _, key in
            directory.setViewing(key, owner: appState.windowStateId)
        }
    }

    /// 지금 앞에 보이는 에이전트 — 나눈 탭이면 포커스된 패널, 아니면 탭 자신.
    private var viewingKey: String? {
        guard appState.windowKind == .workspace, let tab = appState.selectedSession else { return nil }
        let pane = panes.group(for: tab)?.focusedSession ?? tab
        return directory.agent(for: pane, includeStale: true)?.key
    }
}

extension TabSurfaceContent {
    @ViewBuilder
    fileprivate func newTabPicker(layout: WorkspaceLayout) -> some View {
        if let context = interaction.pendingContext {
            let taken = Set(directory.agents.map(\.name)).union(context.backgroundSessions.map(\.name))
                .union(layout.panes.values.compactMap(\.session))
            AgentPickerView(
                workspace: appState.selectedWorkspace?.name ?? layout.workspace,
                context: context,
                initial: AgentPickerDefaults.load(fallback: .init(engine: .claude,
                                                                  modelID: context.claudeModels.first?.id ?? "",
                                                                  effort: .high)),
                suggestName: { appState.suggestedAgentName(for: $0, taken: taken) },
                onOpen: { appState.launchInNewTab($0, layout: layout) },
                onBring: { appState.bringIntoNewTab($0, layout: layout) },
                onCancel: { appState.cancelLayoutSplit() })
        }
    }

    /// 배치로 보이는 워크스페이스의 옛 탭(tmux attach 등)이 이미 붙어 있으면 뗀다. 같은 에이전트를
    /// tmux 보기 창과 sm 패널이 함께 붙들면 창 크기를 서로 바꾼다. tmux 세션 자체는 그대로 둔다.
    fileprivate func closeLegacyTerminalsIfLayoutShown() {
        guard layoutTab != nil else { return }
        for session in appState.sessions where session.terminalView != nil {
            session.cleanup()
        }
    }

    /// 배치 탭의 고르는 상자. 확정하면 세션 층의 split 하나로 배치와 세션이 함께 생긴다.
    @ViewBuilder
    fileprivate func layoutPicker(_ pending: LayoutInteraction.Pending, layout: WorkspaceLayout) -> some View {
        if let context = interaction.pendingContext {
            let taken = Set(directory.agents.map(\.name)).union(context.backgroundSessions.map(\.name))
                .union(layout.panes.values.compactMap(\.session))
            AgentPickerView(
                workspace: appState.selectedWorkspace?.name ?? layout.workspace,
                context: context,
                initial: AgentPickerDefaults.load(fallback: .init(engine: .claude,
                                                                  modelID: context.claudeModels.first?.id ?? "",
                                                                  effort: .high)),
                suggestName: { appState.suggestedAgentName(for: $0, taken: taken) },
                onOpen: { appState.launchInLayout($0, layout: layout) },
                onBring: { appState.bringIntoLayout($0, layout: layout) },
                onCancel: { appState.cancelLayoutSplit() })
        }
    }
}

private struct SplitTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var group: PaneGroup
    @ObservedObject var directory: PeerDirectory

    var body: some View {
        TabPanesView(group: group, badge: { session in
            guard let agent = directory.agent(for: session, includeStale: true) else {
                return PaneBadge(title: session.name)
            }
            return PaneBadge(agent: agent, attention: directory.attention(of: agent))
        }, picker: { id in
            AnyView(picker(for: id))
        })
    }

    @ViewBuilder
    private func picker(for id: UUID) -> some View {
        if let context = group.pickerContexts[id] {
            let taken = Set(directory.agents.map(\.name)).union(context.backgroundSessions.map(\.name))
            AgentPickerView(
                workspace: appState.selectedWorkspace?.name ?? "",
                context: context,
                initial: AgentPickerDefaults.load(fallback: .init(engine: .claude,
                                                                  modelID: context.claudeModels.first?.id ?? "",
                                                                  effort: .high)),
                suggestName: { appState.suggestedAgentName(for: $0, taken: taken) },
                onOpen: { appState.launchAgent($0, inPane: id, group: group) },
                onBring: { appState.attachAgent(named: $0.name, host: appState.selectedWorkspace.flatMap(appState.sessionHost(for:)), inPane: id, group: group) },
                onCancel: { group.cancelPicker(id) })
        }
    }
}


/// 탭 막대를 채운다: 배치가 있으면 배치의 탭, 없으면 지금까지의 탭(tmux·셸).
struct TabStripBar: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var layouts: LayoutDirectory
    @ObservedObject var peers: PeerDirectory
    @ObservedObject var interaction: LayoutInteraction

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = appState.selectedWorkspace, let layout = layouts.layouts[appState.layoutKey(for: workspace)] {
                layoutStrip(layout)
            } else {
                legacyStrip
            }
            Spacer(minLength: 0)
        }
    }

    private func layoutStrip(_ layout: WorkspaceLayout) -> some View {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        let picking = interaction.pendingTab == key
        let active = picking ? nil : appState.displayedTab(of: layout)?.id
        var items = layout.tabs.map { tab in
            WorkspaceTabStrip.Item(id: tab.id, name: tab.name, isActive: tab.id == active,
                                   attention: appState.layoutRollup(tab: tab, in: layout, directory: peers),
                                   isZoomed: tab.zoom != nil, canClose: layout.tabs.count > 1)
        }
        if picking {
            items.append(.init(id: "pending-tab", name: "새 탭", isActive: true, isPending: true, canClose: false))
        }
        return WorkspaceTabStrip(
            items: items,
            onSelect: { id in
                if id == "pending-tab" { return }
                appState.cancelLayoutSplit()
                appState.selectLayoutTab(id, in: layout)
            },
            onClose: { appState.closeLayoutTab($0, in: layout) },
            onRename: { appState.renameLayoutTab($0, to: $1, in: layout) },
            onMove: { appState.moveLayoutTab($0, to: $1, in: layout) },
            onNew: { appState.beginLayoutNewTab(in: layout) })
    }

    private var legacyStrip: some View {
        WorkspaceTabStrip(
            items: appState.sessions.map { session in
                WorkspaceTabStrip.Item(id: session.id.uuidString, name: session.name,
                                       isActive: appState.selectedSession?.id == session.id,
                                       attention: appState.agentRollup(forTab: session, directory: peers),
                                       canClose: session.kind != .tmuxMain)
            },
            onSelect: { id in
                if let session = appState.sessions.first(where: { $0.id.uuidString == id }) { appState.selectSession(session) }
            },
            onClose: { id in
                if let session = appState.sessions.first(where: { $0.id.uuidString == id }) { appState.removeSession(session) }
            },
            onNew: { appState.addDefaultTab() })
    }
}

/// 탭 전체를 차지하는 고르는 상자(새 탭).
struct PickerCardStandalone<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 48)
        }
        .scrollIndicators(.never)
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
        .overlay(PaneRim(isFocused: true, radius: ContentView.cardRadius))
    }
}
