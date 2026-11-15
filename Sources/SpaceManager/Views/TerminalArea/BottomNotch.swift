import SwiftUI

/// 터미널 영역 아래의 두 노치: 왼쪽은 탭 칩, 오른쪽은 화면 밖 에이전트 묶음(SEOL 11/15).
///
/// 탭 막대가 아래 한 줄을 통째로 쓰던 것을, 칩이 놓인 자리만 카드에서 파내고 나머지는 터미널이 차지하게 했다.
/// Claude·Codex의 맨 아랫줄은 상태 표시라 가려져도 일에 지장이 없다. 노치는 맥북 노치처럼 카드 안쪽 모서리는
/// 둥글고(`notchRadius`), 카드 가장자리와 만나는 곳은 바깥으로 살짝 벌어진다(`flareRadius`) — 패널 카드의
/// 모서리와 같은 말로 읽히게.
///
/// 너비는 안에 든 것(칩, 로고)이 정하고 영역 좌표(터미널 영역의 왼쪽 위가 0)로 쓴다. 카드마다 자기 좌표로
/// 바꾼 파낸 자리(`CardCuts`)를 클립과 테두리가 함께 쓴다.
struct BottomNotch: Equatable {
    /// 왼쪽 노치 너비(영역 왼쪽 끝부터). 0이면 없다.
    var left: CGFloat = 0
    /// 오른쪽 노치 너비(영역 오른쪽 끝부터). 0이면 없다.
    var right: CGFloat = 0

    /// 카드 안으로 파고드는 깊이. 칩(22) 위아래에 숨 쉴 자리가 남을 만큼 — 카드 아래 바탕 띠(8)와 합쳐
    /// 칩이 그 가운데 선다.
    static let height: CGFloat = 26
    /// 노치의 카드 안쪽 모서리.
    static let notchRadius: CGFloat = 9
    /// 노치가 카드 아래 가장자리와 만나는 곳의 벌어짐.
    static let flareRadius: CGFloat = 7

    static let none = BottomNotch()
}

private struct BottomNotchKey: EnvironmentKey { static let defaultValue = BottomNotch.none }

extension EnvironmentValues {
    /// 지금 탭 영역의 노치. 패널 카드가 자기 모양을 파낼 때 읽는다.
    var bottomNotch: BottomNotch {
        get { self[BottomNotchKey.self] }
        set { self[BottomNotchKey.self] = newValue }
    }
}

/// 카드 하나에서 파낸 자리(카드 자기 좌표). 아래 가장자리에 붙은 두 구간뿐이다 — 왼쪽 노치와 오른쪽 노치.
/// 구간의 두 끝이 같으면 그 노치는 이 카드에 닿지 않는다. 네 값이 애니메이션된다(탭이 늘면 노치가 넓어진다).
/// 닿지 않는 노치는 자기 쪽 끝에 접어 둔다 — 왼쪽은 0, 오른쪽은 카드 너비. 오른쪽 노치를 0에 접었더니 열리고
/// 닫힐 때 파낸 자리가 카드를 가로질러 왼쪽으로 날아갔다(SEOL 11/15).
struct CardCuts: Equatable {
    var leftStart: CGFloat = 0
    var leftEnd: CGFloat = 0
    var rightStart: CGFloat = 0
    var rightEnd: CGFloat = 0
    var depth: CGFloat = BottomNotch.height

    static let none = CardCuts()

    /// 이 너비의 카드에서 아무 노치도 닿지 않은 상태(오른쪽은 오른쪽 끝에 접는다).
    static func none(width: CGFloat) -> CardCuts {
        CardCuts(rightStart: width + 1, rightEnd: width + 1)
    }

    var isEmpty: Bool { leftEnd - leftStart < 0.5 && rightEnd - rightStart < 0.5 }

    /// 영역 좌표의 카드 `frame`이 노치와 겹치는 자리. 카드가 영역 아래 끝에 닿지 않으면 없다.
    static func of(frame: CGRect, in area: CGSize, notch: BottomNotch) -> CardCuts {
        var cuts = CardCuts.none(width: frame.width)
        guard frame.maxY >= area.height - 1, notch.left > 0 || notch.right > 0 else { return cuts }
        if notch.left > frame.minX {
            cuts.leftStart = -1
            cuts.leftEnd = min(frame.width + 1, notch.left - frame.minX)
        }
        let rightEdge = area.width - notch.right
        if notch.right > 0, rightEdge < frame.maxX {
            cuts.rightStart = max(-1, rightEdge - frame.minX)
            cuts.rightEnd = frame.width + 1
        }
        return cuts
    }
}

/// 파낸 자리를 반영한 카드 윤곽(아래로 갈수록 y가 커지는 좌표). 꼭짓점 목록을 만들고 꼭짓점마다 반지름을 둥글린다 —
/// 볼록(카드 모서리)이든 오목(노치 안쪽)이든 같은 방법이다.
enum CardOutline {
    static func path(in rect: CGRect, cuts: CardCuts, radius: CGFloat, inset: CGFloat = 0) -> CGPath {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 1, r.height > 1 else { return CGPath(rect: r, transform: nil) }
        let depth = cuts.depth + inset
        let top = r.minY, bottom = r.maxY, raised = r.maxY - depth
        let cardRadius = max(0, radius - inset)
        let notchRadius = BottomNotch.notchRadius + inset
        let flareRadius = max(0, BottomNotch.flareRadius - inset)

        // 아래 가장자리에서 파낸 구간(카드 좌표 → 윤곽 좌표). 끝이 카드 밖이면 그 모서리가 통째로 올라간다.
        var spans: [(lo: CGFloat, hi: CGFloat)] = []
        if cuts.leftEnd - cuts.leftStart >= 0.5 {
            spans.append((rect.minX + cuts.leftStart - inset, rect.minX + cuts.leftEnd + inset))
        }
        if cuts.rightEnd - cuts.rightStart >= 0.5 {
            spans.append((rect.minX + cuts.rightStart - inset, rect.minX + cuts.rightEnd + inset))
        }
        guard !spans.isEmpty, raised > top + 2 else {
            return CGPath(roundedRect: r, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        }
        func isCut(_ x: CGFloat) -> Bool { spans.contains { x > $0.lo && x < $0.hi } }

        var points: [(CGPoint, CGFloat)] = [(CGPoint(x: r.minX, y: top), cardRadius), (CGPoint(x: r.maxX, y: top), cardRadius)]
        let probe: CGFloat = 0.25
        points.append((CGPoint(x: r.maxX, y: isCut(r.maxX - probe) ? raised : bottom), cardRadius))
        // 오른쪽에서 왼쪽으로 아래 가장자리를 걸으며, 노치 경계마다 꺾인다.
        var edges: [CGFloat] = []
        for span in spans { edges.append(span.lo); edges.append(span.hi) }
        let inner: (CGFloat) -> Bool = { x in x > r.minX + 0.5 && x < r.maxX - 0.5 }
        edges = edges.filter(inner).sorted(by: >)
        for x in edges {
            let before = isCut(x + probe) ? raised : bottom
            let after = isCut(x - probe) ? raised : bottom
            guard before != after else { continue }
            points.append((CGPoint(x: x, y: before), before == bottom ? flareRadius : notchRadius))
            points.append((CGPoint(x: x, y: after), after == bottom ? flareRadius : notchRadius))
        }
        points.append((CGPoint(x: r.minX, y: isCut(r.minX + probe) ? raised : bottom), cardRadius))
        return rounded(points)
    }

    /// 꼭짓점마다 반지름을 둥글린 닫힌 다각형. 반지름은 이웃 변 길이의 절반을 넘지 않는다.
    static func rounded(_ points: [(CGPoint, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        guard n >= 3 else { return path }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let first = points[0].0, last = points[n - 1].0
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in 0..<n {
            let prev = points[(i + n - 1) % n].0, (point, radius) = points[i], next = points[(i + 1) % n].0
            let limit = min(length(prev, point), length(point, next)) / 2
            path.addArc(tangent1End: point, tangent2End: next, radius: max(0, min(radius, limit)))
        }
        path.closeSubpath()
        return path
    }
}

/// 노치를 파낸 카드 모양. 클립과 머리카락 테두리에 쓴다. 파낸 자리가 바뀌면 스프링으로 따라간다.
struct NotchedCardShape: InsettableShape {
    var cuts: CardCuts
    var radius: CGFloat = ContentView.cardRadius
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(cuts.leftStart, cuts.leftEnd), .init(cuts.rightStart, cuts.rightEnd)) }
        set {
            cuts.leftStart = newValue.first.first
            cuts.leftEnd = newValue.first.second
            cuts.rightStart = newValue.second.first
            cuts.rightEnd = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(CardOutline.path(in: rect, cuts: cuts, radius: radius, inset: inset))
    }

    func inset(by amount: CGFloat) -> NotchedCardShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// 노치 자리를 바탕색으로 덮는 면(영역 좌표의 왼쪽 또는 오른쪽 아래). 카드가 클립으로 이미 비켜 있지만, 터미널
/// 표면(AppKit)이 클립 밖까지 그리거나 클릭을 받는 일이 없게 위에서 한 번 더 덮는다. 카드 쪽 벌어짐과 같은
/// 곡선으로 맞물린다.
struct NotchFillShape: Shape {
    enum Side { case left, right }
    let side: Side
    var width: CGFloat
    /// 영역 아래 바탕 띠까지 덮는 높이(노치 깊이 + 카드 아래 간격).
    var below: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // rect: 영역 전체(아래로 `below`만큼 더). 노치는 영역 아래 끝에서 깊이만큼 올라온다.
        guard width > 0.5 else { return Path() }
        let areaBottom = rect.maxY - below
        let top = areaBottom - BottomNotch.height
        let flare = BottomNotch.flareRadius
        let points: [(CGPoint, CGFloat)]
        switch side {
        case .left:
            let edge = rect.minX + width
            points = [(CGPoint(x: rect.minX - ContentView.cardGap, y: top), 0),
                      (CGPoint(x: edge, y: top), BottomNotch.notchRadius),
                      (CGPoint(x: edge, y: areaBottom), flare),
                      (CGPoint(x: edge + flare * 2, y: areaBottom), 0),
                      (CGPoint(x: edge + flare * 2, y: rect.maxY), 0),
                      (CGPoint(x: rect.minX - ContentView.cardGap, y: rect.maxY), 0)]
        case .right:
            let edge = rect.maxX - width
            points = [(CGPoint(x: rect.maxX + ContentView.cardGap, y: top), 0),
                      (CGPoint(x: rect.maxX + ContentView.cardGap, y: rect.maxY), 0),
                      (CGPoint(x: edge - flare * 2, y: rect.maxY), 0),
                      (CGPoint(x: edge - flare * 2, y: areaBottom), 0),
                      (CGPoint(x: edge, y: areaBottom), flare),
                      (CGPoint(x: edge, y: top), BottomNotch.notchRadius)]
        }
        return Path(CardOutline.rounded(points))
    }
}
