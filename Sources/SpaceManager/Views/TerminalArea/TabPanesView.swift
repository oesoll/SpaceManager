import SwiftUI
import AppKit

/// 나눈 탭. tmux가 그리던 패널 테두리·이름·포커스 표시를 sm이 그린다.
///
/// herdr의 기본값(`pane_gaps`)을 sm의 카드 말로 옮겼다: 패널은 선을 나눠 쓰지 않고 저마다 카드가
/// 되어, 사이드바 카드와 같은 간격·라운딩으로 바탕 위에 선다. 상자 안에 상자를 만들지 않는다.
/// 포커스된 카드만 테두리가 분홍이다(SEOL의 tmux 활성 테두리와 같은 색). 카드 사이 틈이 곧
/// 크기 조절 손잡이다.
///
/// 패널은 화면 좌표로 절대 배치한다. 나누거나 닫아도 남은 패널의 뷰가 다시 만들어지지 않아야
/// 터미널이 다시 붙지 않는다(ForEach의 id가 패널 id다).
struct TabPanesView: View {
    @ObservedObject var group: PaneGroup
    /// 패널 이름표에 쓸 글. 에이전트 매칭은 부르는 쪽이 한다.
    let badge: (TerminalSession) -> PaneBadge
    /// 고르는 중인 자리에 띄울 상자.
    var picker: ((UUID) -> AnyView)?

    static let gap = ContentView.cardGap
    static let radius = ContentView.cardRadius

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let layout = group.isZoomed ? PaneLayout.pane(group.focused) : group.layout
            let frames = layout.frames(in: bounds, divider: Self.gap)
            let dividers = layout.dividers(in: bounds, divider: Self.gap)
            ZStack(alignment: .topLeading) {
                ForEach(group.paneIDs, id: \.self) { id in
                    if let frame = frames[id], group.picking.contains(id), let picker {
                        PickerCard(isFocused: group.focused == id) { picker(id) }
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    } else if let frame = frames[id], let session = group.session(for: id) {
                        PaneCard(session: session,
                                 badge: badge(session),
                                 isFocused: group.focused == id && group.isSplit,
                                 isZoomed: group.isZoomed,
                                 onFocus: { group.focus(id) },
                                 onClose: id == group.anchor.id ? nil : { group.close(id) },
                                 onZoom: { group.toggleZoom() },
                                 onHoverFocus: group.isSplit && group.picking.isEmpty ? {
                                     if group.focused != id { group.focus(id) }
                                 } : nil)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(Array(dividers.enumerated()), id: \.offset) { _, divider in
                    GapHandle(divider: divider) { ratio in group.setRatio(ratio, at: divider.path) }
                }
            }
            .coordinateSpace(name: TabPanesView.space)
        }
    }

    static let space = "TabPanes"
}

/// 패널 하나 = 카드 하나. 카드 윗머리에 이름표를 쓴다 — 바탕도 구분선도 없는 글자 한 줄이라
/// 막대가 아니라 카드의 제목으로 읽힌다. 테두리 위에 얹는 tmux식 이름표는 8pt 틈과 창 윗변에
/// 끼어 답답했다(10/31 캡처).
private struct PaneCard: View {
    @ObservedObject var session: TerminalSession
    let badge: PaneBadge
    let isFocused: Bool
    let isZoomed: Bool
    let onFocus: () -> Void
    let onClose: (() -> Void)?
    let onZoom: () -> Void
    /// 패널이 하나뿐인 탭은 이름표 없이 그린다 — 지금까지의 터미널 카드와 똑같다.
    var showsLegend = true
    /// 이름표 오른쪽 끝의 글자 버튼 하나(예: tmux에 남은 에이전트 옮기기).
    var legendAction: LegendAction?
    /// 이름표 메뉴의 "Fine으로 옮기기". 세션을 보이는 패널에만.
    var onMoveToFine: (() -> Void)?
    /// 포인터가 머물렀을 때 부른다. nil이면 호버로 포커스를 옮기지 않는다(고르는 상자가 떠 있을 때 등).
    var onHoverFocus: (() -> Void)?
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLegend {
                PaneLegend(badge: badge, isFocused: isFocused, isZoomed: isZoomed, action: legendAction)
                    .padding(.leading, 9)
                    .padding(.trailing, 12)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(isZoomed ? "확대 끝내기" : "이 패널 확대", action: onZoom)
                        if let onMoveToFine {
                            Button("Fine으로 옮기기", action: onMoveToFine)
                        }
                        if let onClose {
                            Divider()
                            Button("패널 닫기", action: onClose)
                        }
                    }
            }
            AgentTerminalView(session: session)
                .padding(showsLegend ? EdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 4)
                                     : EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 4))
        }
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous))
        .overlay(PaneRim(isFocused: isFocused))
        .background(PaneFocusMonitor(onPress: onFocus))
        // 포인터가 잠깐 머물면 그 패널로 포커스가 옮겨 간다(SEOL 10/31). 지나가기만 하면 옮기지 않는다 —
        // 여러 패널을 가로질러 갈 때마다 키 입력 대상이 바뀌면 오히려 헷갈린다.
        .onHover { inside in
            hoverWork?.cancel()
            guard inside, let onHoverFocus else { return }
            let work = DispatchWorkItem(block: onHoverFocus)
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }
}

/// 고르는 중인 자리. 터미널 대신 상자가 카드 안에 뜬다 — 고른 것이 바로 이 자리에서 열린다.
private struct PickerCard<Content: View>: View {
    let isFocused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 28)
        }
        .scrollIndicators(.never)
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous))
        .overlay(PaneRim(isFocused: isFocused))
    }
}

/// 이름표: 상태 표시, 이름, 막힌 이유, 경과 시간.
/// 포커스된 패널만 이름이 진하다 — 강조색은 상태 표시와 포커스 테두리에만 쓴다.
struct LegendAction {
    let title: String
    let isEnabled: Bool
    var help: String?
    let run: () -> Void
}

private struct PaneLegend: View {
    let badge: PaneBadge
    let isFocused: Bool
    let isZoomed: Bool
    var action: LegendAction?

    static let height: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            // 표시가 없어도 자리는 둔다 — 상태가 오가도 이름이 밀리지 않는다(사이드바와 같다).
            AgentStateMark(attention: badge.attention)
            Text(badge.title)
                .font(.system(size: 11.5, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(Color(isFocused ? Chrome.textPrimary : Chrome.textSecondary))
            if let detail = badge.detail {
                Text(detail)
                    .font(.system(size: 11, weight: badge.attention == .blocked ? .semibold : .regular))
                    .foregroundStyle(badge.attention == .blocked ? Color(Chrome.accent) : Color(Chrome.textTertiary))
            }
            if badge.showsAge, let since = badge.since {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(PaneBadge.age(since: since, now: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color(Chrome.textTertiary))
                }
            }
            if let notice = badge.notice {
                // 노치의 ×와 같다: 노치에서 지우면 sm에서도, 여기서 지우면 노치에서도 사라진다.
                Button { MainActor.assumeIsolated { NotchOwner.shared.dismiss(notice.id) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color(Chrome.textTertiary))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("알림 지우기 (노치에서도 지워짐)")
            }
            if isZoomed {
                Text("확대")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
            if let action {
                Spacer(minLength: 8)
                Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(action.isEnabled ? Chrome.textSecondary : Chrome.textTertiary))
                        .underline(action.isEnabled)
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .help(action.help ?? action.title)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .help(badge.help)
    }
}

/// 카드 사이 틈. 보이지 않는 손잡이라 끌면 두 패널의 경계가 손가락을 1:1로 따라간다.
private struct GapHandle: View {
    let divider: PaneDivider
    let onRatio: (Double) -> Void
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: divider.line.width, height: divider.line.height)
            .offset(x: divider.line.minX, y: divider.line.minY)
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TabPanesView.space))
                    .onChanged { value in
                        onRatio(divider.ratio(at: value.location, divider: TabPanesView.gap))
                    }
            )
    }
}

/// 패널 안 어디를 눌러도 그 패널로 포커스가 옮겨 간다. 터미널 표면(AppKit 뷰)이 마우스를 먼저 받으므로
/// SwiftUI 제스처로는 못 잡는다 — 창의 마우스 다운을 엿보고 이벤트는 그대로 흘려보낸다.
/// 누르는 순간 옮긴다(놓을 때가 아니라).
private struct PaneFocusMonitor: NSViewRepresentable {
    let onPress: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onPress = onPress
    }

    final class MonitorView: NSView {
        var onPress: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.onPress?() }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}


// MARK: - 배치 데이터로 그리는 탭

/// 세션 층의 배치(`WorkspaceLayout`) 탭 하나. 모양은 위의 카드 그대로이고, 다른 점은 원본이 파일이라는 것뿐이다.
/// 끌기는 화면에서만 미리 보이고 놓을 때 한 번 명령을 보낸다. 고르는 상자 자리는 데이터에 쓰기 전의 미리보기다.
struct LayoutTabView: View {
    @EnvironmentObject private var appState: AppState
    let layout: WorkspaceLayout
    let tab: WorkspaceLayout.Tab
    let workspace: Workspace
    @ObservedObject var interaction: LayoutInteraction
    @ObservedObject var directory: PeerDirectory
    let picker: (LayoutInteraction.Pending) -> AnyView
    /// 겹쳐 둔 탭 가운데 지금 보이는 탭인가. 숨은 탭은 포커스 테두리·호버·클릭·키 입력을 받지 않는다.
    var isShown = true
    @State private var drag: (path: [Int], sizes: [Double])?
    @EnvironmentObject private var terminalLayout: TerminalLayoutTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 배치가 바뀌면(나누기·닫기·확대·고르는 상자 자리) 카드가 새 자리로 미끄러진다. 튀지 않는 스프링이다 —
    /// 사람이 던진 움직임이 아니라 명령의 결과라서 넘쳤다 돌아올 까닭이 없다(apple-design: damping 1.0).
    static let layoutSpring = Animation.spring(response: 0.32, dampingFraction: 1.0)
    /// 위 스프링이 눈에 띄게 움직이는 시간. 그동안 터미널은 크기를 그대로 두고, 멈춘 뒤 한 번만 새 크기를 받는다 —
    /// 프레임마다 크기를 바꾸면 에이전트가 프레임마다 화면을 다시 그린다.
    static let layoutSettle: TimeInterval = 0.42

    /// 애니메이션을 거는 모양: 끄는 중의 몫은 넣지 않는다(끄는 동안은 손을 1:1로 따라가야 한다).
    private struct Shape: Equatable {
        let root: LayoutNode
        let zoom: String?
    }

    private var workspaceKey: String { LayoutDirectory.key(workspace: layout.workspace, host: layout.host) }

    /// 지금 그릴 트리: 파일 → 놓은 직후의 모양 → 끄는 중의 모양 → 상자 자리.
    private var root: LayoutNode {
        var node = settledRoot
        if let drag { node = node.resizing(path: drag.path, sizes: drag.sizes) }
        if let pending { node = node.inserting(pending.paneID, beside: pending.beside, dir: pending.dir) }
        return node
    }

    /// 파일 → 놓은 직후의 모양(끄는 중 제외).
    private var settledRoot: LayoutNode {
        if let held = interaction.rootOverride, held.key == LayoutInteraction.tabKey(layout, tab.id), layout.version < held.until {
            return held.root
        }
        return tab.root
    }

    private var shape: Shape {
        var node = settledRoot
        if let pending { node = node.inserting(pending.paneID, beside: pending.beside, dir: pending.dir) }
        return Shape(root: node, zoom: pending == nil ? tab.zoom : nil)
    }

    private func holdTerminalsWhileMoving() {
        guard isShown, !reduceMotion else { return }
        let transition = terminalLayout.begin()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutSettle) { terminalLayout.finish(transition) }
    }

    private var pending: LayoutInteraction.Pending? {
        guard let pending = interaction.pending, pending.workspaceKey == workspaceKey, pending.tabID == tab.id else { return nil }
        return pending
    }

    private var focused: String? {
        if let pending { return pending.paneID }
        if let override = interaction.focusOverride, override.key == workspaceKey, tab.root.paneIDs.contains(override.pane) {
            return override.pane
        }
        return tab.focus
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let tree = root
            let zoomed = pending == nil ? tab.zoom.flatMap { tree.paneIDs.contains($0) ? $0 : nil } : nil
            let shown: LayoutNode = zoomed.map { .pane(id: $0, size: 1) } ?? tree
            let frames = shown.frames(in: bounds, gap: TabPanesView.gap)
            let boundaries = zoomed == nil ? tree.boundaries(in: bounds, gap: TabPanesView.gap) : []
            let multiple = tree.paneIDs.count > 1
            ZStack(alignment: .topLeading) {
                ForEach(shown.paneIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        paneView(id, multiple: multiple, zoomed: zoomed != nil)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            // 새 자리(고르는 상자)는 이웃 아래에 깔려, 이웃이 물러나는 만큼 드러난다. 최종 자리에
                            // 먼저 떠서 아직 줄어드는 이웃 위에 겹쳐 비치지 않게. 확대되는 패널은 맨 위에서 커진다.
                            .zIndex(id == pending?.paneID ? 0 : id == zoomed ? 2 : 1)
                    }
                }
                ForEach(Array(boundaries.enumerated()), id: \.offset) { _, boundary in
                    LayoutGapHandle(boundary: boundary) { point in
                        drag = (boundary.path, boundary.sizes(at: point, gap: TabPanesView.gap))
                    } onEnd: {
                        if let drag { appState.commitResize(boundary, sizes: drag.sizes, tab: tab, in: layout) }
                        drag = nil
                    }
                }
            }
            .coordinateSpace(name: TabPanesView.space)
            .animation(isShown && !reduceMotion ? Self.layoutSpring : nil, value: shape)
        }
        .onChange(of: shape) { _, _ in holdTerminalsWhileMoving() }
        .environment(\.paneShown, isShown)
        // 탭이 앞에 나오면 그 탭의 포커스된 패널이 바로 키를 받는다 — 전에는 떼어 낸 터미널과 함께 키 받을
        // 곳이 사라져, 탭을 바꾼 뒤 한 번 눌러야 글자가 들어갔다.
        .onAppear { if isShown { focusKeyboard() } }
        .onChange(of: isShown) { _, shown in if shown { focusKeyboard() } }
        // 테두리와 키가 같은 패널을 가리키게. 세션 층은 누가 그렇게 하라고 할 때만 포커스를 옮긴다 — `sm focus`,
        // 포커스된 패널 닫기, SEOL의 클릭·호버. 배치만 바꾸는 명령(split·move·arrange)은 옮기지 않으니(11/01),
        // 에이전트가 패널을 붙여도 SEOL이 치던 패널의 키는 그대로다.
        .onChange(of: focused) { _, _ in if isShown { focusKeyboard() } }
    }

    private func focusKeyboard() {
        guard let focused, pending == nil, layout.panes[focused] != nil || tab.root.paneIDs.contains(focused) else { return }
        appState.layoutTerminals.session(for: focused, in: layout, workspace: workspace).focusTerminal()
    }

    @ViewBuilder
    private func paneView(_ id: String, multiple: Bool, zoomed: Bool) -> some View {
        if let pending, pending.paneID == id {
            PickerCard(isFocused: true) { picker(pending) }
        } else {
            let session = appState.layoutTerminals.session(for: id, in: layout, workspace: workspace)
            PaneCard(session: session,
                     badge: badge(for: id, session: session),
                     isFocused: isShown && multiple && focused == id,
                     isZoomed: zoomed,
                     onFocus: { if isShown && focused != id { appState.focusLayoutPane(id, in: layout) } },
                     onClose: multiple ? { appState.closeLayoutPane(id, in: layout) } : nil,
                     onZoom: { appState.zoomLayoutPane(id, in: layout) },
                     showsLegend: multiple,
                     legendAction: migrateAction(for: id, session: session),
                     // Fine 탭은 Claude·Codex만 보인다 — 에이전트(peer 행)가 있는 패널에만.
                     onMoveToFine: agent(for: id) != nil && !isInTmux(id)
                        ? { appState.moveLayoutPaneToFine(id, in: layout) } : nil,
                     onHoverFocus: isShown && multiple && pending == nil && drag == nil ? {
                         guard focused != id else { return }
                         appState.focusLayoutPane(id, in: layout)
                         session.focusTerminal()
                     } : nil)
        }
    }

    /// 아직 tmux에 남은 에이전트를 sm 세션으로 옮기는 버튼. 쉬는 중일 때만 켠다 — 일하는 중에 옮기면
    /// 그 턴이 끊긴다. 하네스 lane(dori-*)은 등록부 주소를 하네스가 먼저 바꿔야 해서 하네스가 옮긴다.
    private func migrateAction(for id: String, session: TerminalSession) -> LegendAction? {
        guard isInTmux(id), let name = layout.panes[id]?.session else { return nil }
        if name.hasPrefix("dori-") {
            return LegendAction(title: "하네스가 옮김", isEnabled: false,
                                help: "하네스가 등록부 주소를 바꾼 뒤 옮긴다", run: {})
        }
        let idle = agent(for: id).map { $0.state == .idle } ?? false
        return LegendAction(title: "sm으로 옮기기", isEnabled: idle,
                            help: idle ? "같은 대화를 sm 세션으로 옮긴다" : "쉬는 상태가 되면 옮길 수 있다",
                            run: { appState.migrateToSessionLayer(name, host: layout.host) })
    }

    /// 이 패널의 에이전트 — 배치가 말하는 세션 이름(이름이 곧 세션이자 peer 이름)으로 찾는다.
    private func agent(for id: String) -> PeerAgent? {
        guard let name = layout.panes[id]?.session else { return nil }
        return directory.agents.first { $0.name == name && $0.host == layout.host }
    }

    private func badge(for id: String, session: TerminalSession) -> PaneBadge {
        let title = layout.panes[id]?.session ?? session.name
        var badge = agent(for: id)
            .map { PaneBadge(agent: $0, attention: directory.attention(of: $0), notice: directory.notice(for: $0), title: title) }
            ?? directory.terminalNotice(for: session).map { PaneBadge(title: title, notice: $0) }
            ?? PaneBadge(title: title)
        // 아직 tmux에 남은 에이전트. 쉬는 상태가 되면 sm으로 옮길 수 있다.
        if isInTmux(id), badge.detail == nil { badge.detail = "tmux" }
        return badge
    }

    /// 에이전트가 아직 tmux 칸에서 도는가. 배치의 tmux_pane은 옮긴 뒤에도 보기 창으로 남으므로
    /// 그것만으로는 모른다 — peer가 보고하는 위치(target)가 tmux 칸(`%NN`)이면 아직 tmux다.
    private func isInTmux(_ id: String) -> Bool {
        guard layout.panes[id]?.tmuxPane != nil, let agent = agent(for: id) else { return false }
        return agent.target.hasPrefix("%")
    }
}

/// 배치 경계선의 손잡이(카드 사이 틈 전체). 끄는 동안은 화면만, 놓을 때 한 번.
private struct LayoutGapHandle: View {
    let boundary: LayoutBoundary
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: boundary.line.width, height: boundary.line.height)
            .offset(x: boundary.line.minX, y: boundary.line.minY)
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    (boundary.dir == .row ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TabPanesView.space))
                    .onChanged { onChange($0.location) }
                    .onEnded { _ in onEnd() }
            )
    }
}
