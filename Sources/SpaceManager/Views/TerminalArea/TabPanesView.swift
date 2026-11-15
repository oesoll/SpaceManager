import SwiftUI
import AppKit

/// 패널 카드의 치수. 사이드바 카드와 같은 간격·라운딩으로 바탕 위에 선다(herdr의 `pane_gaps`를 sm의 카드 말로).
enum TabPanesView {
    static let gap = ContentView.cardGap
    static let radius = ContentView.cardRadius
    static let space = "TabPanes"
}

/// 패널 하나 = 카드 하나. 터미널이 카드 위 끝까지 차고, 이름표는 우상단에 떠 있는 작은 캡슐이다(SEOL 11/15).
/// 예전에는 카드 윗머리 한 줄을 이름표가 통째로 썼다.
///
/// 캡슐이나 카드 윗가장자리를 잡고 끌면 카드가 손을 1:1로 따라온다(잡은 자리를 지킨다). 다른 패널 위에서
/// 놓으면 두 패널이 자리를 바꾸고(`sm swap`), 빈 데서 놓으면 제자리로 돌아간다. 몇 pt 움직이기 전에는 끌기로
/// 보지 않는다 — 캡슐을 눌러 포커스만 옮기려던 손이 카드를 흔들지 않게.
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
    /// 아래 노치에 파낸 자리(카드 좌표).
    var cuts: CardCuts = .none
    /// 끌어서 자리 바꾸기. nil이면 끌 수 없다(패널이 하나뿐인 탭).
    var drag: PaneDragHandlers?
    /// 들려서 끌리는 중이다.
    var isLifted = false
    /// 끌던 카드를 여기 놓으면 자리를 바꾼다.
    var isDropTarget = false
    @State private var hoverWork: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let grabHeight: CGFloat = 8

    var body: some View {
        AgentTerminalView(session: session)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 4))
            .background(Color(Chrome.pane))
            .clipShape(NotchedCardShape(cuts: cuts, radius: TabPanesView.radius))
            .overlay(PaneRim(isFocused: isFocused, cuts: cuts))
            .overlay {
                if isDropTarget {
                    NotchedCardShape(cuts: cuts, radius: TabPanesView.radius)
                        .fill(Color(Chrome.accent).opacity(0.10))
                        .overlay(NotchedCardShape(cuts: cuts, radius: TabPanesView.radius)
                            .strokeBorder(Color(Chrome.accent).opacity(0.8), lineWidth: 2))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                // 윗가장자리 손잡이. 터미널 첫 줄을 거의 가리지 않을 만큼만 얇다.
                if let drag {
                    PaneGrab(handlers: drag, onClick: onFocus, menu: menuItems)
                        .frame(height: Self.grabHeight)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsLegend {
                    legend
                        .padding(.top, 6)
                        .padding(.trailing, 8)
                }
            }
            .background(PaneFocusMonitor(onPress: onFocus))
            .scaleEffect(isLifted && !reduceMotion ? 0.985 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.35 : 0), radius: isLifted ? 22 : 0, y: isLifted ? 10 : 0)
            .opacity(isLifted ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1.0), value: isLifted)
            .animation(.easeOut(duration: 0.12), value: isDropTarget)
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

    /// 이름표·손잡이의 우클릭 메뉴.
    private var menuItems: [PaneGrab.MenuItem] {
        var items = [PaneGrab.MenuItem(title: isZoomed ? "확대 끝내기" : "이 패널 확대", run: onZoom)]
        if let onMoveToFine { items.append(.init(title: "Fine으로 옮기기", run: onMoveToFine)) }
        if let onClose { items.append(.init(title: "패널 닫기", run: onClose, separatorBefore: true)) }
        return items
    }

    private var legend: some View {
        PaneLegend(badge: badge, isFocused: isFocused, isZoomed: isZoomed, action: legendAction,
                   grab: PaneGrab(handlers: drag, onClick: onFocus, menu: menuItems))
            .padding(.horizontal, 8)
            .frame(height: PaneLegend.capsuleHeight)
            // 떠 있는 층: 아래 글자가 비치되 이름은 읽히게 반투명 재질 위에, 머리카락 선으로 맺는다.
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(Chrome.hairline), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// 끌어서 자리 바꾸기. 좌표는 창 내용(위가 0)이다 — 받는 쪽이 자기 영역 좌표로 옮긴다.
struct PaneDragHandlers {
    let changed: (_ translation: CGSize, _ windowLocation: CGPoint) -> Void
    let ended: () -> Void
}

/// 잡는 자리(카드 윗가장자리, 이름표). 터미널 표면 위에 겹친 SwiftUI 제스처는 끌기를 받지 못해서(11/15 시험)
/// AppKit 뷰가 마우스를 직접 받는다. 비활성 창에서도 첫 클릭부터 잡힌다(Finder처럼).
/// 몇 pt 움직이기 전에는 끌기로 보지 않고, 그냥 놓으면 누른 것으로 친다(그 패널로 포커스).
struct PaneGrab: NSViewRepresentable {
    struct MenuItem {
        let title: String
        let run: () -> Void
        var separatorBefore = false
    }

    let handlers: PaneDragHandlers?
    let onClick: () -> Void
    let menu: [MenuItem]

    func makeNSView(context: Context) -> PaneGrabView {
        let view = PaneGrabView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PaneGrabView, context: Context) {
        view.handlers = handlers
        view.onClick = onClick
        view.items = menu
    }
}

final class PaneGrabView: NSView {
    var handlers: PaneDragHandlers? { didSet { window?.invalidateCursorRects(for: self) } }
    var onClick: (() -> Void)?
    var items: [PaneGrab.MenuItem] = []

    /// 이만큼 움직여야 끌기다 — 눌러서 포커스만 옮기려던 손이 카드를 흔들지 않게.
    static let threshold: CGFloat = 5
    private var start: CGPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if handlers != nil { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    }

    /// 창 내용 좌표(위가 0). SwiftUI의 `.global`과 같다.
    private func contentPoint(_ event: NSEvent) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        start = contentPoint(event)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handlers, let start, let point = contentPoint(event) else { return }
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        if !dragging {
            guard hypot(translation.width, translation.height) >= Self.threshold else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        handlers.changed(translation, point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; dragging = false }
        if dragging {
            NSCursor.pop()
            handlers?.ended()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: item.title, action: #selector(runItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.run
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func runItem(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}

/// 고르는 중인 자리. 터미널 대신 상자가 카드 안에 뜬다 — 고른 것이 바로 이 자리에서 열린다.
private struct PickerCard<Content: View>: View {
    let isFocused: Bool
    var cuts: CardCuts = .none
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 28)
        }
        .scrollIndicators(.never)
        .background(Color(Chrome.pane))
        .clipShape(NotchedCardShape(cuts: cuts, radius: TabPanesView.radius))
        .overlay(PaneRim(isFocused: isFocused, cuts: cuts))
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
    /// 이름 쪽을 잡아 끄는 손잡이. 단추(알림 지우기, 옮기기)는 손잡이 밖에 둔다.
    var grab: PaneGrab?

    static let height: CGFloat = 14
    static let capsuleHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            info
                .overlay { if let grab { grab.padding(-4) } }
            buttons
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: Self.height)
    }

    private var info: some View {
        HStack(spacing: 4) {
            // 표시가 없으면 자리도 두지 않는다 — 떠 있는 캡슐은 짧을수록 아래 글자를 덜 가린다.
            if let attention = badge.attention, attention >= .working {
                AgentStateMark(attention: attention)
            }
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
            if isZoomed {
                Text("확대")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
        }
        .help(badge.help + "\n끌어서 다른 패널과 자리 바꾸기")
    }

    @ViewBuilder
    private var buttons: some View {
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
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(action.isEnabled ? Chrome.textSecondary : Chrome.textTertiary))
                        .underline(action.isEnabled)
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .help(action.help ?? action.title)
                .padding(.leading, 4)
            }
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
    /// 끌어서 자리를 바꾸는 중인 카드: 손이 움직인 만큼, 지금 손이 올라 있는 다른 패널.
    @State private var swap: (pane: String, translation: CGSize, target: String?)?
    @State private var swapTransition: Int?
    @Environment(\.bottomNotch) private var notch
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
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                ForEach(shown.paneIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        let lifted = swap?.pane == id
                        paneView(id, multiple: multiple, zoomed: zoomed != nil,
                                 cuts: lifted ? .none(width: frame.width) : CardCuts.of(frame: frame, in: bounds.size, notch: notch),
                                 frames: frames, origin: origin)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX + (lifted ? swap?.translation.width ?? 0 : 0),
                                    y: frame.minY + (lifted ? swap?.translation.height ?? 0 : 0))
                            // 새 자리(고르는 상자)는 이웃 아래에 깔려, 이웃이 물러나는 만큼 드러난다. 최종 자리에
                            // 먼저 떠서 아직 줄어드는 이웃 위에 겹쳐 비치지 않게. 확대되는 패널은 맨 위에서 커진다.
                            // 끌리는 카드는 모든 카드 위로 들린다.
                            .zIndex(lifted ? 3 : id == pending?.paneID ? 0 : id == zoomed ? 2 : 1)
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
    private func paneView(_ id: String, multiple: Bool, zoomed: Bool, cuts: CardCuts,
                          frames: [String: CGRect], origin: CGPoint) -> some View {
        if let pending, pending.paneID == id {
            PickerCard(isFocused: true, cuts: cuts) { picker(pending) }
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
                     onHoverFocus: isShown && multiple && pending == nil && drag == nil && swap == nil ? {
                         guard focused != id else { return }
                         appState.focusLayoutPane(id, in: layout)
                         session.focusTerminal()
                     } : nil,
                     cuts: cuts,
                     drag: isShown && multiple && zoomed == false && pending == nil ? swapHandlers(for: id, frames: frames, origin: origin) : nil,
                     isLifted: swap?.pane == id,
                     isDropTarget: swap?.target == id)
        }
    }

    /// 끌어서 자리 바꾸기. 끄는 동안은 화면에서만 움직이고(터미널 크기는 그대로), 놓을 때 명령 하나를 보낸다.
    /// 놓은 자리가 다른 패널이면 그 모양을 결과가 올 때까지 먼저 그려 카드가 곧장 새 자리로 미끄러진다.
    /// `origin`: 이 탭 영역의 창 내용 좌표 — 손잡이가 알려 주는 창 좌표를 영역 좌표로 옮긴다.
    private func swapHandlers(for id: String, frames: [String: CGRect], origin: CGPoint) -> PaneDragHandlers {
        PaneDragHandlers(changed: { translation, windowLocation in
            let location = CGPoint(x: windowLocation.x - origin.x, y: windowLocation.y - origin.y)
            if swap == nil {
                // 들리는 순간: 터미널은 크기를 그대로 둔다(놓은 뒤 한 번만 새 크기를 받는다).
                if isShown { swapTransition = terminalLayout.begin() }
                if focused != id { appState.focusLayoutPane(id, in: layout) }
            }
            let target = frames.first { $0.key != id && $0.value.contains(location) }?.key
            swap = (id, translation, target)
        }, ended: {
            guard let current = swap else { return }
            let spring = reduceMotion ? Animation.easeOut(duration: 0.15) : Self.layoutSpring
            if let target = current.target {
                appState.swapLayoutPanes(current.pane, target, tab: tab, in: layout)
            }
            withAnimation(spring) { swap = nil }
            let transition = swapTransition
            swapTransition = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutSettle) {
                if let transition { terminalLayout.finish(transition) }
            }
        })
    }

    /// 아직 tmux에 남은 에이전트를 sm 세션으로 옮기는 버튼. 쉬는 중일 때만 켠다 — 일하는 중에 옮기면
    /// 그 턴이 끊긴다. 하네스 lane(dori-*)은 등록부 주소를 하네스가 먼저 바꿔야 해서 하네스가 옮긴다.
    private func migrateAction(for id: String, session: TerminalSession) -> LegendAction? {
        guard isInTmux(id), let (name, host) = layout.agent(inPane: id) else { return nil }
        if name.hasPrefix("dori-") {
            return LegendAction(title: "하네스가 옮김", isEnabled: false,
                                help: "하네스가 등록부 주소를 바꾼 뒤 옮긴다", run: {})
        }
        let idle = agent(for: id).map { $0.state == .idle } ?? false
        return LegendAction(title: "sm으로 옮기기", isEnabled: idle,
                            help: idle ? "같은 대화를 sm 세션으로 옮긴다" : "쉬는 상태가 되면 옮길 수 있다",
                            run: { appState.migrateToSessionLayer(name, host: host) })
    }

    /// 이 패널의 에이전트 — 배치가 말하는 세션 이름(이름이 곧 세션이자 peer 이름)으로 찾는다.
    private func agent(for id: String) -> PeerAgent? {
        guard let (name, host) = layout.agent(inPane: id) else { return nil }
        return directory.agents.first { $0.name == name && $0.host == host }
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
