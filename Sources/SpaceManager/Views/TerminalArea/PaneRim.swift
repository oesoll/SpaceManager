import SwiftUI
import AppKit

/// 패널 카드의 테두리. 평소에는 머리카락 선, 포커스된 패널은 옅은 분홍 위로 빛 한 줄기가 천천히 돈다
/// (SEOL 10/31: "그라데이션으로 색 테두리가 윙윙 돌도록, 몰입이 될 정도로만"). 포커스가 옮겨 가면
/// 색이 바로 바뀌지 않고 페이드로 넘어간다.
///
/// 회전은 Core Animation에 맡겨 렌더 서버에서 돈다 — SwiftUI 애니메이션은 매 프레임 메인 스레드를
/// 깨워 CPU를 쓴다(사이드바 스피너에서 실측한 이유와 같다). 다만 도는 그라데이션은 카드만 한 층이라
/// 창 서버가 매 프레임 카드 전체를 다시 합성한다. 120Hz로 두 창이 돌자 WindowServer가 35% 안팎을
/// 계속 썼다(10/31 실측). 그래서 초당 20번으로 묶고(8초 한 바퀴엔 충분히 매끄럽다), 지금 앞에 있는
/// 창의 포커스된 카드만 돌린다. 동작 줄이기를 켜면 돌지 않고 옅은 분홍 테두리만 남는다.
struct PaneRim: View {
    let isFocused: Bool
    var radius: CGFloat = TabPanesView.radius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color(Chrome.hairline), lineWidth: 1)
                .opacity(isFocused ? 0 : 1)
            FlowingRim(isActive: isFocused, radius: radius, moves: !reduceMotion)
                .opacity(isFocused ? 1 : 0)
        }
        // 0.3초는 손이 먼저 가 있는 사람에게 굼뜨게 느껴졌다(SEOL 10/31 "버벅거린다").
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .allowsHitTesting(false)
    }
}

private struct FlowingRim: NSViewRepresentable {
    let isActive: Bool
    let radius: CGFloat
    let moves: Bool

    func makeNSView(context: Context) -> FlowingRimView { FlowingRimView() }

    func updateNSView(_ view: FlowingRimView, context: Context) {
        view.radius = radius
        view.setActive(isActive && moves)
    }
}

final class FlowingRimView: NSView {
    var radius: CGFloat = 12 { didSet { needsLayout = true } }
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var isActive = false
    /// 한 바퀴. 눈에 걸리지 않고 곁눈에 흐름만 느껴질 만큼 느리게.
    static let period: CFTimeInterval = 8
    static let lineWidth: CGFloat = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = Self.lineWidth
        layer?.mask = ring
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 대각선만큼 큰 정사각형 위에 그라데이션을 깔아, 돌려도 모서리가 비지 않게 한다.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = Self.lineWidth / 2
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil)
        CATransaction.commit()
    }

    /// 동적 색은 CALayer에 넘길 때 고정되므로 외형이 바뀔 때마다 다시 푼다.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = Chrome.accent
            // 바탕은 옅은 분홍(예전 테두리보다 한참 낮다), 한 군데만 밝아지는 빛 한 줄기.
            let base = accent.withAlphaComponent(0.32).cgColor
            let glow = accent.withAlphaComponent(0.95).cgColor
            let soft = accent.withAlphaComponent(0.55).cgColor
            gradient.colors = [base, base, soft, glow, soft, base, base]
            gradient.locations = [0, 0.55, 0.68, 0.75, 0.82, 0.95, 1]
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        observeWindow()
        // 창에 다시 붙으면 CA가 지운 애니메이션을 새로 건다.
        gradient.removeAnimation(forKey: "spin")
        refreshAnimation()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        refreshAnimation()
    }

    private var windowObservers: [NSObjectProtocol] = []

    /// 창에서 떨어지면 CA가 애니메이션을 지우므로 붙을 때마다 다시 건다. 포커스가 없거나, 이 창이
    /// 앞에 있지 않으면(다른 창·다른 앱을 보는 중) 멈춘다 — 보지 않는 곳에서 창 서버를 쓰지 않게.
    private func refreshAnimation() {
        let running = gradient.animation(forKey: "spin") != nil
        let shouldRun = isActive && window?.isKeyWindow == true && NSApp.isActive
        guard running != shouldRun else { return }
        guard shouldRun else {
            gradient.removeAnimation(forKey: "spin")
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
        gradient.add(spin, forKey: "spin")
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refreshAnimation()
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAnimation()
            })
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
