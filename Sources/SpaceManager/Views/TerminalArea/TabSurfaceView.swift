import SwiftUI

/// 터미널 카드의 내용. 나누지 않은 탭은 지금처럼 터미널 하나를 그리고, 나눈 탭은 패널 분할을 그린다.
/// 이 창이 떠 있는 동안 peer 목록을 받아 패널 이름 줄에 에이전트 상태를 붙인다.
struct TabSurfaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabSurfaceContent(panes: appState.panes, directory: .shared)
    }
}

private struct TabSurfaceContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var panes: PaneStore
    @ObservedObject var directory: PeerDirectory

    private var group: PaneGroup? {
        guard appState.windowKind == .workspace, let tab = appState.selectedSession,
              let group = panes.group(for: tab), group.isSplit else { return nil }
        return group
    }

    var body: some View {
        Group {
            if let group {
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
        }
        .onDisappear {
            guard appState.windowKind == .workspace else { return }
            directory.stop(owner: appState.windowStateId)
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
