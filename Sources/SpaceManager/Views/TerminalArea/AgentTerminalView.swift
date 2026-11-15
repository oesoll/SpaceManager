import SwiftUI
import AppKit
import GhosttyTerminal

/// Terminal view for a single session
struct AgentTerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let error = session.startError {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(.secondary)
                Button("다시 시도") {
                    session.restartIfDead()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 재연결 중에도 터미널을 그대로 둔다 — 끊기기 전 마지막 화면 위에 문구만 얹는다.
            SessionTerminalWrapper(session: session)
                .overlay(alignment: .topTrailing) {
                    // 무대가 맡은 패널은 무대가 "연결 중"을 보인다(얼린 화면·막·빛·글).
                    if session.isReconnecting && session.stageDirector == nil {
                        ReconnectingBadge(detail: nil) {
                            session.reconnectIfNeeded()
                        }
                    }
                }
        }
    }
}

/// 터미널 우상단의 재연결 표시. 터미널과 같은 글꼴·셀 높이로 tmux 메시지 줄처럼 그려
/// 화면의 일부로 읽히게 한다. 애니메이션은 없다 — 호스트가 잠든 동안 몇 시간이고 떠 있을
/// 수 있어, 프레임마다 메인 스레드를 깨우는 표시는 그 시간 내내 CPU를 쓴다.
private struct ReconnectingBadge: View {
    let detail: String?
    let retryNow: () -> Void

    /// terminal.html의 xterm 설정(D2Coding 우선, 13pt)과 맞춘다.
    private static let font = Font(NSFont(name: "D2Coding", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))

    var body: some View {
        Text(" 연결 재시도 중… ")
            .font(Self.font)
            .foregroundColor(Color(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255))
            .background(Color.reconnectAmber)
            .padding(.top, 2)
            .padding(.trailing, 16)
            .onTapGesture(perform: retryNow)
            .help(detail.map { "\($0)\n클릭하면 바로 다시 연결합니다" } ?? "클릭하면 바로 다시 연결합니다")
            .accessibilityLabel("원격 연결 재시도 중")
            .accessibilityAddTraits(.isButton)
    }
}

/// 세션 소유 터미널 뷰를 SwiftUI에 안전하게 호스팅한다.
///
/// 선택 변경에도 컨테이너는 유지하고 캐시된 터미널만 교체한다. 화면 밖의
/// SwiftUI 계층이 실제 창의 터미널을 빼앗지 않도록 창에 붙은 호스트만 claim한다.
/// 겹쳐 둔 배치 탭 가운데 지금 보이는 탭 안인가(`LayoutTabView`가 정한다). 기본은 보인다.
private struct PaneShownKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var paneShown: Bool {
        get { self[PaneShownKey.self] }
        set { self[PaneShownKey.self] = newValue }
    }
}

struct SessionTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject private var terminalLayout: TerminalLayoutTransition
    @Environment(\.paneShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// 작업 창 터미널은 창의 라이트/다크를 따른다. 보이는 세션만 갱신하고,
    /// 다른 탭은 다시 보일 때 이 경로를 지나며 맞춰진다.
    private func syncPalette() {
        session.palette = colorScheme == .dark ? .workspaceDark : .workspaceLight
    }

    /// 겹쳐 둔 탭 가운데 가려진 세션 패널은 처음 보일 때까지 attach를 띄우지 않는다. 앱을 켜거나 워크스페이스를
    /// 고를 때 그 안 모든 탭의 세션이 한꺼번에 깨지 않게(세션 층은 attach가 열리면 잠든 세션을 깨운다).
    private var waitsUntilShown: Bool {
        guard !shown, session.terminalView == nil, case .agent = session.attachment else { return false }
        return true
    }

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        syncPalette()
        terminalLayout.attach(host)
        host.animatesTransitions = !reduceMotion
        if let director = session.stageDirector {
            // 세션 패널: 표면 대신 무대를 둔다. 보이는 패널만 무대를 깨운다(보는 것이 곧 깨우기).
            host.showStage(director.stage)
            if shown { director.begin() }
            return host
        }
        guard !waitsUntilShown else { return host }
        let terminal = session.getOrCreateTerminal()
        terminal.isShown = shown
        host.show(terminal)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        syncPalette()
        terminalLayout.attach(host)
        host.animatesTransitions = !reduceMotion
        if let director = session.stageDirector {
            let changed = host.showStage(director.stage)
            if shown {
                let starting = !director.isActive
                director.begin()
                if (changed || starting) && host.window != nil { session.focusTerminal() }
            }
            return
        }
        guard !waitsUntilShown else { return }
        let terminal = session.getOrCreateTerminal()
        terminal.isShown = shown
        let changed = host.show(terminal)
        // 포커스는 실제 화면에 있는 계층에서만
        if changed && host.window != nil && shown {
            session.focusTerminal()
        }
    }
}

/// One coordinator per window; a stale animation completion cannot release a
/// newer transition. No timer or per-frame observation is needed.
///
/// 창의 모든 터미널을 붙든다. 전에는 마지막에 붙은 호스트 하나만 기억해서, 패널이 여럿이면 사이드바가 접히는
/// 동안 나머지 터미널은 프레임마다 크기가 바뀌었다(그때마다 에이전트가 화면을 다시 그린다).
final class TerminalLayoutTransition: ObservableObject {
    private let hosts = NSHashTable<TerminalHostView>.weakObjects()
    private var generation = 0
    private var isActive = false

    func attach(_ host: TerminalHostView) {
        hosts.add(host)
        host.setResizeDeferred(isActive)
    }

    @discardableResult
    func begin() -> Int {
        generation += 1
        isActive = true
        hosts.allObjects.forEach { $0.setResizeDeferred(true) }
        return generation
    }

    func finish(_ transition: Int) {
        guard transition == generation else { return }
        // Even a nil (Reduce Motion) animation must commit its SwiftUI layout
        // before the terminal receives the final size.
        DispatchQueue.main.async { [weak self] in
            guard let self, transition == self.generation else { return }
            self.isActive = false
            let hosts = self.hosts.allObjects
            hosts.first?.window?.contentView?.layoutSubtreeIfNeeded()
            hosts.forEach { $0.setResizeDeferred(false) }
        }
    }
}

/// 터미널 뷰를 담는 컨테이너. 윈도우에 붙은 컨테이너만 터미널을 소유한다.
final class TerminalHostView: NSView {
    private(set) weak var terminal: GhosttyTerminalView?
    var animatesTransitions = true
    private var outgoing: GhosttyTerminalView?
    private var swapGeneration = 0
    private var resizeDeferred = false
    private var liveResize = false
    private let preparePresentation: (GhosttyTerminalView, @escaping () -> Void) -> Void

    override var isFlipped: Bool { true }

    init(frame: NSRect = .zero,
         preparePresentation: @escaping (GhosttyTerminalView, @escaping () -> Void) -> Void = { view, completion in
             view.prepareForPresentation(completion)
         }) {
        self.preparePresentation = preparePresentation
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setResizeDeferred(_ deferred: Bool) {
        guard resizeDeferred != deferred else { return }
        resizeDeferred = deferred
        if deferred { settling = false } else { releaseWhenStill(previous: nil, checks: 0) }
    }

    /// 놓은 뒤에도 크기가 한 프레임 동안 그대로일 때 비로소 터미널에 준다. 스프링은 눈에 띄게 멈춘 뒤에도
    /// 1px 아래로 몇 프레임 더 움직이는데, 그때마다 크기를 주면 PTY 크기(픽셀 포함)가 바뀌어 에이전트가
    /// 다시 그렸다(10/31 측정: 놓은 뒤 크기 9번). 곡선에 기대지 않고 멈춘 것을 보고 준다.
    private var settling = false

    private func releaseWhenStill(previous: NSRect?, checks: Int) {
        guard !resizeDeferred else { return }
        settling = true
        if bounds == previous || checks >= 40 {
            settling = false
            updateViewport()
            return
        }
        let now = bounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.releaseWhenStill(previous: now, checks: checks + 1)
        }
    }

    /// 무대(세션 패널)를 둔다. 표면 바꿔 끼우기·크기 주기는 무대가 안에서 하고, 여기서는 무대의 크기만 준다
    /// (사이드바가 접히는 동안 미루는 것은 터미널과 같다).
    private(set) weak var stage: NSView?

    @discardableResult
    func showStage(_ next: NSView) -> Bool {
        guard stage !== next || next.superview !== self else { updateViewport(); return false }
        terminal = nil
        outgoing = nil
        swapGeneration += 1
        for view in subviews where view !== next { view.removeFromSuperview() }
        stage = next
        next.translatesAutoresizingMaskIntoConstraints = true
        next.autoresizingMask = []
        next.frame = NSRect(origin: .zero, size: resizeDeferred ? next.frame.size : bounds.size)
        addSubview(next)
        updateViewport()
        return true
    }

    @discardableResult
    func show(_ next: GhosttyTerminalView) -> Bool {
        stage?.removeFromSuperview()
        stage = nil
        let changed = terminal !== next
        if changed, window != nil, outgoing === next {
            // A→B→A before B has painted: the visible A is already correct.
            swapGeneration += 1
            for view in subviews where view !== next {
                (view as? GhosttyTerminalView)?.cancelPresentation()
                view.removeFromSuperview()
            }
            next.cancelPresentation()
            next.layer?.removeAllAnimations()
            next.alphaValue = 1
            outgoing = nil
        }
        terminal = next
        attachIfNeeded()
        updateViewport()
        return changed
    }

    func attachIfNeeded() {
        guard let terminal, window != nil else { return }
        guard terminal.superview !== self else { return }
        swapGeneration += 1
        let generation = swapGeneration
        // Keep at most two surfaces, including during rapid A→B→C selection.
        // The outgoing view stays opaque until WebKit acknowledges a new frame.
        let previous = outgoing ?? subviews.compactMap { $0 as? GhosttyTerminalView }.first
        for view in subviews where view !== previous {
            (view as? GhosttyTerminalView)?.cancelPresentation()
            view.removeFromSuperview()
        }
        previous?.cancelPresentation()
        previous?.layer?.removeAllAnimations()
        previous?.alphaValue = 1
        outgoing = previous
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        // A tab selected midway through a panel animation uses the held viewport
        // too. Hidden sessions never receive intermediate sizes.
        // 배치가 움직이는 중에 새로 붙는 터미널은 중간 크기를 받지 않는다 — 받으면 그 크기로 자식이 떠서
        // 에이전트가 한 번 잘못 그린다(처음 열 때 깨지던 것과 같은 일). 움직임이 끝나면 최종 크기로 시작한다.
        terminal.frame = NSRect(origin: .zero, size: resizeDeferred ? (previous?.frame.size ?? .zero) : bounds.size)
        terminal.alphaValue = 1
        addSubview(terminal, positioned: .below, relativeTo: previous)
        terminal.layoutSubtreeIfNeeded()
        NSAnimationContext.endGrouping()
        preparePresentation(terminal) { [weak self, weak terminal] in
            guard let self, let terminal,
                  self.swapGeneration == generation, self.terminal === terminal else { return }
            guard let previous = self.outgoing else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.animatesTransitions ? 0.22 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                previous.animator().alphaValue = 0
            } completionHandler: { [weak self, weak previous] in
                guard let self, self.swapGeneration == generation else { return }
                previous?.removeFromSuperview()
                previous?.alphaValue = 1
                self.outgoing = nil
            }
        }
    }

    private func updateViewport() {
        guard !resizeDeferred, !settling, !liveResize, !inLiveResize, bounds.width > 0, bounds.height > 0 else { return }
        if let stage, stage.superview === self {
            if stage.frame != bounds { stage.frame = bounds; stage.layoutSubtreeIfNeeded() }
            return
        }
        guard let terminal, terminal.superview === self else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
            terminal.layoutSubtreeIfNeeded()
        }
    }

    // Pointer input always belongs to the selected tab, even while the old
    // surface covers it during the fade. The old PTY cannot receive stray clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let stage, stage.superview === self {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            return stage.hitTest(convert(local, to: stage.superview)) ?? stage
        }
        guard let terminal, terminal.superview === self else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return terminal.hitTest(local) ?? terminal
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
        updateViewport()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResize = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResize = false
        // AppKit clears inLiveResize after delivering the end notification.
        DispatchQueue.main.async { [weak self] in self?.updateViewport() }
    }
}
