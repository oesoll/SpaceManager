import SwiftUI

/// 사이드바 오른쪽: 고른 워크스페이스의 탭(패널 카드들)이 창 아래 끝까지 내려오고, 아래 두 노치에 탭 칩과
/// 다른 탭에 있는 에이전트 묶음이 선다(`BottomNotch`). 미리보기는 오른쪽 노치에서 위로 뜬다.
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var layouts = LayoutDirectory.shared
    @ObservedObject private var peers = PeerDirectory.shared
    @StateObject private var preview = AgentPreview()
    @State private var notch = BottomNotch.none
    /// 탭을 고른 순간(파일이 따라잡기 전) 묶음도 바로 바뀌게 화면 쪽 상태를 따라 다시 그린다.
    @State private var interactionTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 노치 안쪽 여백. 왼쪽은 칩이 카드 세로줄에 가깝게, 오른쪽은 노치 곡선에서 숨 쉴 만큼.
    static let leadingInset: CGFloat = 4
    static let trailingInset: CGFloat = 10

    private var layoutKey: String? {
        appState.selectedWorkspace.map { appState.layoutKey(for: $0) }
    }

    /// 지금 탭 말고 다른 탭(그리고 확대에 가려진 패널)의 세션. 배치와 peer만으로 계산한다.
    private var shelfAgents: [ShelfAgent] {
        _ = interactionTick
        guard let workspace = appState.selectedWorkspace,
              let layout = layouts.layouts[appState.layoutKey(for: workspace)] else { return [] }
        return appState.hiddenAgents(in: layout, directory: peers)
    }

    /// 노치 폭, 칩과 묶음이 바뀌는 움직임. 위 화면의 탭·워크스페이스 전환과 같은 스프링이라 한 몸으로 움직인다.
    private var resize: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)
    }

    /// 워크스페이스가 바뀔 때 칩이 들어오는 쪽: 위 화면처럼 사이드바에서 아래면 아래에서, 위면 위에서.
    @State private var lastWorkspaceIndex = 0
    private var workspaceIndex: Int {
        appState.workspaces.firstIndex { $0.id == appState.selectedWorkspace?.id } ?? 0
    }
    private var chipsEnter: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dy: CGFloat = workspaceIndex >= lastWorkspaceIndex ? 8 : -8
        return .asymmetric(insertion: .offset(y: dy).combined(with: .opacity),
                           removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
    /// 처음 잰 폭은 움직이지 않고 바로 둔다(창이 뜰 때 노치가 자라나지 않게).
    @State private var measured = (left: false, right: false)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let band = BottomNotch.height + ContentView.cardGap
            ZStack(alignment: .topLeading) {
                // 카드 바탕·테두리는 TabSurfaceView가 그린다 — 탭을 나누면 카드가 여럿이 된다. 카드는 노치 자리를 파낸다.
                TabSurfaceView()
                    .environment(\.bottomNotch, notch)
                    .frame(width: size.width, height: size.height)

                // 노치 자리를 바탕색으로 한 번 더 덮는다 — 터미널 표면(AppKit)이 클립 밖에 그리거나 그 자리의 클릭을
                // 받지 않게. 모양 안만 클릭을 받는다.
                ZStack {
                    NotchFillShape(side: .left, width: notch.left, below: ContentView.cardGap)
                    NotchFillShape(side: .right, width: notch.right, below: ContentView.cardGap)
                }
                .foregroundStyle(Color(Chrome.canvas))
                .frame(width: size.width, height: size.height + ContentView.cardGap)

                // 왼쪽 노치: 탭 칩. 오른쪽 노치 몫을 남기고 그보다 길면 옆으로 민다. 워크스페이스가 바뀌면 칩 묶음이
                // 통째로 바뀐다 — 떠나는 칩은 빨리 흐려지고, 새 칩은 위 화면과 같은 쪽에서 들어온다.
                ZStack(alignment: .topLeading) {
                    TabStripBar(layouts: .shared, peers: .shared, interaction: appState.layoutInteraction,
                                maxWidth: max(120, size.width - notch.right - 160))
                        .padding(.leading, Self.leadingInset)
                        .padding(.trailing, Self.trailingInset)
                        .frame(height: band)
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            let next = appState.selectedLayout == nil ? 0 : width
                            guard next != notch.left else { return }
                            if measured.left || next == 0 {
                                withAnimation(resize) { notch.left = next }
                            } else {
                                notch.left = next
                            }
                            if next > 0 { measured.left = true }
                        }
                        .id(layoutKey ?? "")
                        .transition(chipsEnter)
                }
                .animation(resize ?? .easeOut(duration: 0.15), value: layoutKey)
                .offset(y: size.height - BottomNotch.height)

                // 오른쪽 노치: 다른 탭에 있는 에이전트 묶음. 없으면 노치도 없다.
                // 생길 때는 노치가 오른쪽 끝에서 열리며 로고가 따라 나오고, 사라질 때는 로고가 먼저 흐려진 뒤 노치가 닫힌다.
                ZStack(alignment: .trailing) {
                    if !shelfAgents.isEmpty {
                        AgentShelf(agents: shelfAgents) { agent in openPreview(agent) }
                            .fixedSize()
                            .frame(height: band)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                guard width != notch.right else { return }
                                withAnimation(resize) { notch.right = width }
                            }
                            // 워크스페이스를 바꿀 때는 새 묶음이 먼저 폭을 잴 수 있다 — 정말 비었을 때만 닫는다.
                            .onDisappear { if shelfAgents.isEmpty { withAnimation(resize) { notch.right = 0 } } }
                            .id(layoutKey ?? "")
                            .transition(reduceMotion ? .opacity
                                        : .asymmetric(insertion: .offset(x: 10).combined(with: .opacity),
                                                      removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                }
                .frame(width: size.width, height: band, alignment: .trailing)
                .animation(resize ?? .easeOut(duration: 0.15), value: shelfAgents.isEmpty)
                .animation(resize ?? .easeOut(duration: 0.15), value: layoutKey)
                .offset(y: size.height - BottomNotch.height)

                // 미리보기: 오른쪽 노치 위에 뜬다(노치가 원점 — 닫으면 그리로 돌아간다).
                if let agent = preview.agent, let session = preview.session {
                    let width = min(860, max(420, size.width * 0.62))
                    let height = min(600, max(280, size.height * 0.62))
                    AgentPreviewCard(agent: agent, session: session,
                                     attention: shelfAgents.first { $0.id == agent.id }?.attention ?? agent.attention,
                                     onGoToTab: { goToTab(agent) },
                                     onClose: closePreview)
                        .frame(width: width, height: height)
                        .offset(x: size.width - width - 4, y: size.height - BottomNotch.height - height - 8)
                        .transition(reduceMotion ? .opacity
                                    : .scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                        .zIndex(5)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1.0),
                       value: preview.agent?.id)
        }
        .onChange(of: layoutKey) { _, _ in closePreview() }
        .onChange(of: appState.selectedWorkspace?.id) { _, _ in
            // 다음 전환의 방향을 정할 기준(이번 전환의 칩은 이미 그려졌다).
            DispatchQueue.main.async { lastWorkspaceIndex = workspaceIndex }
        }
        .onReceive(appState.layoutInteraction.objectWillChange) { _ in
            DispatchQueue.main.async { interactionTick &+= 1 }
        }
        // 미리보던 세션의 탭으로 갔거나 그 패널이 사라지면 미리보기는 할 일이 끝났다.
        .onChange(of: shelfAgents.map(\.id)) { _, ids in
            if let agent = preview.agent, !ids.contains(agent.id) { closePreview() }
        }
        .onDisappear { preview.close() }
    }

    /// 도는 세션은 미리보기, 쉬는(잠든) 세션은 그 탭으로 — 붙으면 깨어나므로 미리보기로 깨우지 않는다.
    private func openPreview(_ agent: ShelfAgent) {
        guard let workspace = appState.selectedWorkspace else { return }
        if agent.isRunning {
            preview.open(agent, workingDirectory: workspace.rootPath)
        } else {
            goToTab(agent)
        }
    }

    private func closePreview() {
        preview.close()
    }

    /// 그 세션이 있는 탭으로 가서 그 패널에 포커스(확대 중이었으면 세션 층이 그 탭을 앞에 둔다).
    private func goToTab(_ agent: ShelfAgent) {
        guard let layout = appState.selectedLayout else { return }
        closePreview()
        appState.focusLayoutPane(agent.pane, in: layout)
    }
}
