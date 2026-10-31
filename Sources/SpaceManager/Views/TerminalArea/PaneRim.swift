import SwiftUI
import AppKit

/// 패널 카드의 테두리. 평소에는 머리카락 선, 포커스된 패널은 옅은 분홍 위로 빛 한 줄기가 천천히 돈다
/// (SEOL 10/31: "그라데이션으로 색 테두리가 윙윙 돌도록, 몰입이 될 정도로만"). 포커스가 옮겨 가면
/// 색이 바로 바뀌지 않고 페이드로 넘어간다.
///
/// 회전도 페이드도 Core Animation에 맡겨 렌더 서버에서 돈다. 처음엔 페이드를 SwiftUI 애니메이션으로
/// 걸었는데, SwiftUI는 매 프레임 메인 스레드에서 값을 밀어 넣는다. 포커스가 바뀌는 바로 그 순간 메인
/// 스레드는 두 터미널의 포커스를 바꾸고 화면을 다시 계산하느라 바빠서, 0.15초짜리 페이드가 몇 장면으로
/// 끊겼다(SEOL 10/31 "페이드 인 아웃 애니메이션의 프레임이 조금 낮은 느낌"). 렌더 서버의 애니메이션은
/// 메인 스레드가 바빠도 화면 주사율대로 돈다.
///
/// 도는 그라데이션은 카드만 한 층이라 창 서버가 매 프레임 카드 전체를 다시 합성한다. 120Hz로 두 창이
/// 돌자 WindowServer가 35% 안팎을 계속 썼다(10/31 실측). 그래서 회전만 초당 30번으로 묶고(20번은
/// 빛줄기가 끊겨 보였다), 지금 앞에 있는 창의 포커스된 카드만 돌린다. 페이드는 묶지 않는다 — 0.2초뿐이다.
/// 동작 줄이기를 켜면 돌지 않고 옅은 분홍 테두리만 남는다(페이드는 남긴다).
struct PaneRim: View {
    let isFocused: Bool
    var radius: CGFloat = TabPanesView.radius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RimRepresentable(isFocused: isFocused, radius: radius, moves: !reduceMotion)
            .allowsHitTesting(false)
    }
}

private struct RimRepresentable: NSViewRepresentable {
    let isFocused: Bool
    let radius: CGFloat
    let moves: Bool

    func makeNSView(context: Context) -> PaneRimView {
        let view = PaneRimView()
        view.radius = radius
        view.moves = moves
        view.setFocused(isFocused, animated: false)
        return view
    }

    func updateNSView(_ view: PaneRimView, context: Context) {
        view.radius = radius
        view.moves = moves
        view.setFocused(isFocused, animated: true)
    }
}

final class PaneRimView: NSView {
    var radius: CGFloat = 12 { didSet { if radius != oldValue { needsLayout = true } } }
    var moves = true { didSet { if moves != oldValue { refreshSpin() } } }
    private(set) var isFocused = false

    private let hairline = CAShapeLayer()
    private let glow = CALayer()
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()

    /// 한 바퀴. 눈에 걸리지 않고 곁눈에 흐름만 느껴질 만큼 느리게.
    static let period: CFTimeInterval = 8
    static let lineWidth: CGFloat = 1.5
    /// 들어올 때는 조금 빠르게, 나갈 때는 조금 느리게 — 눈은 새로 켜진 쪽을 먼저 찾는다.
    static let fadeIn: CFTimeInterval = 0.18
    static let fadeOut: CFTimeInterval = 0.24

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(hairline)
        layer?.addSublayer(glow)
        hairline.fillColor = nil
        hairline.lineWidth = 1
        glow.addSublayer(gradient)
        glow.mask = ring
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = Self.lineWidth
        // 크기·경로가 바뀔 때 CA가 멋대로 애니메이션하지 않게(창 크기를 바꿀 때 테두리가 늦게 따라온다).
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(),
                                         "frame": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        for layer in [hairline, glow, gradient, ring] as [CALayer] { layer.actions = still }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.frame = bounds
        hairline.path = Self.roundedPath(bounds, inset: 0.5, radius: radius)
        glow.frame = bounds
        // 대각선만큼 큰 정사각형 위에 그라데이션을 깔아, 돌려도 모서리가 비지 않게 한다.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.frame = bounds
        ring.path = Self.roundedPath(bounds, inset: Self.lineWidth / 2, radius: radius)
        CATransaction.commit()
    }

    private static func roundedPath(_ rect: CGRect, inset: CGFloat, radius: CGFloat) -> CGPath {
        let corner = max(0, radius - inset)
        return CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: corner, cornerHeight: corner,
                      transform: nil)
    }

    /// 동적 색은 CALayer에 넘길 때 고정되므로 외형이 바뀔 때마다 다시 푼다.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hairline.strokeColor = Chrome.hairline.cgColor
            let accent = Chrome.accent
            // 바탕은 옅은 분홍(예전 테두리보다 한참 낮다), 한 군데만 밝아지는 빛 한 줄기.
            let base = accent.withAlphaComponent(0.32).cgColor
            let shine = accent.withAlphaComponent(0.95).cgColor
            let soft = accent.withAlphaComponent(0.55).cgColor
            gradient.colors = [base, base, soft, shine, soft, base, base]
            gradient.locations = [0, 0.55, 0.68, 0.75, 0.82, 0.95, 1]
        }
    }

    func setFocused(_ focused: Bool, animated: Bool) {
        guard focused != isFocused || glow.opacity != (focused ? 1 : 0) else { return }
        isFocused = focused
        let duration = focused ? Self.fadeIn : Self.fadeOut
        fade(glow, to: focused ? 1 : 0, duration: animated ? duration : 0)
        fade(hairline, to: focused ? 0 : 1, duration: animated ? duration : 0)
        refreshSpin()
    }

    /// 지금 보이는 값에서 출발한다 — 빠르게 오가며 포커스가 바뀌어도 튀지 않는다.
    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = value
        guard duration > 0, window != nil, from != value else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = value
        fade.duration = duration * Double(abs(value - from))
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        observeWindow()
        // 창에서 떨어지면 CA가 애니메이션을 지우므로 붙을 때마다 다시 건다.
        gradient.removeAnimation(forKey: "spin")
        refreshSpin()
    }

    private var windowObservers: [NSObjectProtocol] = []

    /// 포커스가 없거나, 이 창이 앞에 있지 않으면(다른 창·다른 앱을 보는 중) 멈춘다 — 보지 않는 곳에서
    /// 창 서버를 쓰지 않게. 멈출 때는 그 자리에 세우고 다시 돌 때는 거기서 잇는다. 처음 자리로 되돌리면
    /// 페이드 아웃하는 동안 빛줄기가 한 번 튄다.
    private func refreshSpin() {
        let running = gradient.animation(forKey: "spin") != nil
        let shouldRun = isFocused && moves && window?.isKeyWindow == true && NSApp.isActive
        guard running != shouldRun else { return }
        let angle = (gradient.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (gradient.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.removeAnimation(forKey: "spin")
        gradient.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard shouldRun else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = angle
        spin.toValue = angle - 2 * Double.pi
        spin.duration = Self.period
        spin.repeatCount = .infinity
        // 20은 빛줄기가 끊겨 보였다(SEOL 10/31). 30이면 매끄럽고, 120Hz의 4분의 1이다.
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        gradient.add(spin, forKey: "spin")
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refreshSpin()
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSpin()
            })
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// 켜고 끌 때 렌더 서버에서 페이드하는 둥근 면. 탭 칩의 활성 표시처럼, 바뀌는 순간 메인 스레드가
/// 바쁜 자리에 쓴다(탭을 바꾸면 패널 배치 전체를 다시 그린다). 이유는 `PaneRim`과 같다.
struct FadingFill: NSViewRepresentable {
    let isOn: Bool
    let color: NSColor
    var radius: CGFloat = 6

    func makeNSView(context: Context) -> FadingFillView {
        let view = FadingFillView()
        view.configure(color: color, radius: radius)
        view.set(isOn, animated: false)
        return view
    }

    func updateNSView(_ view: FadingFillView, context: Context) {
        view.configure(color: color, radius: radius)
        view.set(isOn, animated: true)
    }
}

final class FadingFillView: NSView {
    private let fill = CALayer()
    private var color: NSColor = .clear
    private var isOn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.cornerCurve = .continuous
        fill.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
                        "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        fill.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fill.frame = bounds
    }

    func configure(color: NSColor, radius: CGFloat) {
        fill.cornerRadius = radius
        guard color != self.color else { return }
        self.color = color
        resolveColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColor()
    }

    private func resolveColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { fill.backgroundColor = color.cgColor }
    }

    func set(_ on: Bool, animated: Bool) {
        guard on != isOn || fill.opacity != (on ? 1 : 0) else { return }
        isOn = on
        let target: Float = on ? 1 : 0
        let from = fill.presentation()?.opacity ?? fill.opacity
        fill.removeAnimation(forKey: "fade")
        fill.opacity = target
        guard animated, window != nil, from != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = (on ? PaneRimView.fadeIn : PaneRimView.fadeOut) * Double(abs(target - from))
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fill.add(fade, forKey: "fade")
    }
}
