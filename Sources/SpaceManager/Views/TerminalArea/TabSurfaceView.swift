import SwiftUI

/// 터미널 카드의 내용: 고른 워크스페이스의 배치(세션 층 파일)에서 지금 탭의 패널들.
/// 이 창이 떠 있는 동안 peer 목록을 받아 패널 이름 줄에 에이전트 상태를 붙인다.
struct TabSurfaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabSurfaceContent(directory: .shared, layouts: .shared, interaction: appState.layoutInteraction)
    }
}

private struct TabSurfaceContent: View {
    @EnvironmentObject private var appState: AppState
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

    /// 고른 워크스페이스의 배치와 지금 보일 탭.
    private var layoutTab: (WorkspaceLayout, WorkspaceLayout.Tab, Workspace)? {
        guard let workspace = appState.selectedWorkspace,
              let layout = layouts.layouts[appState.layoutKey(for: workspace)], let tab = appState.displayedTab(of: layout) else { return nil }
        return (layout, tab, workspace)
    }

    /// 지금 보이는 탭(배치 키/탭). 바뀌면 떠난 패널의 마지막으로 보인 때를 적는다.
    private var displayedTabKey: String? {
        layoutTab.map { LayoutInteraction.tabKey($0.0, $0.1.id) }
    }

    /// 이 워크스페이스에 배치가 있는지 아직 모른다 — 빈 카드로 기다린다.
    private var layoutUndecided: Bool {
        guard let workspace = appState.selectedWorkspace else { return false }
        return !layouts.isSettled(appState.layoutKey(for: workspace), remote: workspace.isRemote)
    }

    /// 이 창이 따라갈 원격 배치(선택된 원격 워크스페이스 하나).
    private var remoteLayoutKeys: Set<String> {
        guard let workspace = appState.selectedWorkspace, workspace.isRemote else { return [] }
        return [appState.layoutKey(for: workspace)]
    }

    private var workspaceIndex: Int {
        appState.workspaces.firstIndex { $0.id == appState.selectedWorkspace?.id } ?? 0
    }

    var body: some View {
        Group {
            if layoutUndecided {
                EmptyCard()
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
            } else if let workspace = appState.selectedWorkspace {
                // 배치가 없는 워크스페이스: 세션 층에 셸 탭 하나짜리 배치를 만든다(tmux 메인 탭이 하던 출발점).
                MissingLayoutCard(workspace: workspace, interaction: interaction)
                    .transition(.identity)
            } else {
                EmptyCard(message: "워크스페이스가 없습니다")
                    .transition(.identity)
            }
        }
        .animation(switchAnimation, value: appState.selectedWorkspace?.id)
        .onChange(of: appState.selectedWorkspace?.id) { _, _ in lastWorkspaceIndex = workspaceIndex }
        .onAppear {
            directory.start(owner: appState.windowStateId)
            layouts.start(owner: appState.windowStateId)
            layouts.setRemote(remoteLayoutKeys, owner: appState.windowStateId)
        }
        .onDisappear {
            directory.stop(owner: appState.windowStateId)
            layouts.stop(owner: appState.windowStateId)
        }
        .onChange(of: remoteLayoutKeys) { _, keys in
            layouts.setRemote(keys, owner: appState.windowStateId)
        }
        // 가려진 지 오래된 세션 패널의 attach를 내린다(LayoutTerminals.parkHidden). 분 단위면 충분하다.
        .onReceive(Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()) { _ in
            appState.parkHiddenLayoutTerminals()
        }
        // 창이 다시 보이면(가림이 걷힘·앞으로 나옴·sm 보이기) 내려 둔 패널을 바로 다시 붙인다.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            appState.resumeDisplayedLayoutTerminals()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            appState.resumeDisplayedLayoutTerminals()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            appState.resumeDisplayedLayoutTerminals()
        }
        // 탭·워크스페이스를 바꾼 순간이 떠난 패널이 마지막으로 보인 때다(LayoutTerminals.note).
        .onChange(of: displayedTabKey) { _, _ in
            appState.resumeDisplayedLayoutTerminals()
        }
        .onChange(of: layouts.layouts) { _, _ in
            appState.pruneLayoutTerminals()
            // 파일이 따라잡았으면 화면 쪽 임시 상태를 걷는다.
            if let layout = layoutTab?.0 { appState.settleLayoutOverrides(layout) }
        }
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

/// 탭 영역 전체를 차지하는 카드의 모양: 아래 노치를 파낸 둥근 사각형.
private struct AreaCard<Content: View>: View {
    @Environment(\.bottomNotch) private var notch
    var focused = false
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let cuts = CardCuts.of(frame: CGRect(origin: .zero, size: proxy.size), in: proxy.size, notch: notch)
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color(Chrome.pane))
                .clipShape(NotchedCardShape(cuts: cuts))
                .overlay(PaneRim(isFocused: focused, radius: ContentView.cardRadius, cuts: cuts))
        }
    }
}

/// 내용이 없는 카드(배치를 기다리는 동안 등).
private struct EmptyCard: View {
    var message: String?

    var body: some View {
        AreaCard {
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
        }
    }
}

/// 배치가 없는 워크스페이스. 보이자마자 세션 층에 배치를 만들고(`ws new`), 못 만들면 까닭과 다시 시도를 보인다.
///
/// 만드는 동안은 상태를 말한다 — 다만 0.4초 안에 끝나는 보통의 경우에는 아무것도 비치지 않게 늦게 띄운다
/// (번쩍 나타났다 사라지는 글은 오히려 소음이다). 실패는 무슨 일인지 → 까닭 → 할 일 순서로 세운다.
private struct MissingLayoutCard: View {
    @EnvironmentObject private var appState: AppState
    let workspace: Workspace
    @ObservedObject var interaction: LayoutInteraction
    @State private var showsProgress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failure: String? {
        if case .failed(let message) = interaction.layoutCreation[appState.layoutKey(for: workspace)] { return message }
        return nil
    }

    var body: some View {
        AreaCard {
            ZStack {
                if let failure {
                    VStack(spacing: 6) {
                        Text("\(workspace.name)을 열지 못했습니다")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(Chrome.textPrimary))
                        Text(workspace.isRemote ? "\(workspace.remoteHost ?? "")에 닿지 않거나 세션 층이 답하지 않았습니다."
                                                : "세션 층이 이 워크스페이스의 배치를 만들지 못했습니다.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(Chrome.textSecondary))
                        Text(failure)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(Chrome.textTertiary))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: 440)
                            .padding(.top, 2)
                        Button("다시 시도") {
                            showsProgress = false
                            appState.createLayout(for: workspace, retry: true)
                            scheduleProgress()
                        }
                        .buttonStyle(PressScaleStyle())
                        .padding(.top, 10)
                        .keyboardShortcut(.defaultAction)
                    }
                    .transition(.opacity)
                } else if showsProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(workspace.name) 준비 중")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(Chrome.textSecondary))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.2), value: failure)
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.2), value: showsProgress)
        }
        .onAppear { start() }
        .onChange(of: workspace.id) { _, _ in start() }
    }

    private func start() {
        showsProgress = false
        appState.createLayout(for: workspace)
        scheduleProgress()
    }

    private func scheduleProgress() {
        let id = workspace.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if workspace.id == id { showsProgress = true }
        }
    }
}


/// 탭 막대를 채운다: 고른 워크스페이스 배치의 탭.
struct TabStripBar: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var layouts: LayoutDirectory
    @ObservedObject var peers: PeerDirectory
    @ObservedObject var interaction: LayoutInteraction
    var maxWidth: CGFloat = .infinity

    var body: some View {
        if let workspace = appState.selectedWorkspace, let layout = layouts.layouts[appState.layoutKey(for: workspace)] {
            layoutStrip(layout)
        }
    }

    private func layoutStrip(_ layout: WorkspaceLayout) -> some View {
        let key = LayoutDirectory.key(workspace: layout.workspace, host: layout.host)
        let picking = interaction.pendingTab == key
        let active = picking ? nil : appState.displayedTab(of: layout)?.id
        var items = layout.tabs.map { tab in
            WorkspaceTabStrip.Item(id: tab.id, name: tab.name, isActive: tab.id == active,
                                   attention: appState.layoutRollup(tab: tab, in: layout, directory: peers),
                                   isZoomed: tab.zoom != nil, canClose: layout.tabs.count > 1,
                                   notices: appState.layoutNotices(tab: tab, in: layout, directory: peers).map(\.id),
                                   canMoveToFine: appState.movableToFine(tab: tab, in: layout) != nil)
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
            onMoveToFine: { id in
                guard let tab = layout.tabs.first(where: { $0.id == id }),
                      let pane = appState.movableToFine(tab: tab, in: layout) else { return }
                appState.moveLayoutPaneToFine(pane, in: layout)
            },
            onNew: { appState.beginLayoutNewTab(in: layout) },
            maxWidth: maxWidth)
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
        .modifier(AreaCardShape())
    }
}

/// `AreaCard`와 같은 모양을 이미 있는 뷰에 입힌다(스크롤 뷰처럼 자기 크기를 정하는 것).
private struct AreaCardShape: ViewModifier {
    @Environment(\.bottomNotch) private var notch

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let cuts = CardCuts.of(frame: CGRect(origin: .zero, size: proxy.size), in: proxy.size, notch: notch)
            content
                .background(Color(Chrome.pane))
                .clipShape(NotchedCardShape(cuts: cuts))
                .overlay(PaneRim(isFocused: true, radius: ContentView.cardRadius, cuts: cuts))
        }
    }
}
