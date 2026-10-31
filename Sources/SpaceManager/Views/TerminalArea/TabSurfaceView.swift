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

    var body: some View {
        Group {
            if layoutUndecided {
                Color(Chrome.pane)
                    .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous)
                        .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
            } else if let layout = layoutTab?.0, interaction.pendingTab == LayoutDirectory.key(workspace: layout.workspace, host: layout.host) {
                // 새 탭: 탭 전체가 고르는 상자 하나다.
                PickerCardStandalone { newTabPicker(layout: layout) }
            } else if let (layout, tab, workspace) = layoutTab {
                LayoutTabView(layout: layout, tab: tab, workspace: workspace, interaction: interaction,
                              directory: directory) { pending in
                    AnyView(layoutPicker(pending, layout: layout))
                }
                .id(LayoutInteraction.tabKey(layout, tab.id))
            } else if let group {
                SplitTab(group: group, directory: directory)
            } else if appState.windowKind == .workspace {
                // 작업 창은 카드 라운딩이 없어 글자가 세로선에 붙는다. 셀 한 칸 남짓 들인다.
                SingleTerminalView()
                    .padding(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 4))
                    // 카드가 팔레트와 같은 색을 깔아 터미널 둘레 여백도 같은 면으로 읽힌다.
                    .background(Color(Chrome.pane))
                    .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous)
                        .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
            } else {
                SingleTerminalView()
                    .background(Color(nsColor: GlassSurfacePolicy.terminalCardColor(for: appState.windowKind)))
            }
        }
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
