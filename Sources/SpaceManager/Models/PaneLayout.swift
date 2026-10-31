import Foundation
import CoreGraphics

/// 탭 하나 안의 패널 배치. tmux 창 안의 분할을 sm이 직접 갖는다 — 배치의 원본이 sm이라
/// 그 아래에서 터미널을 붙든 쪽(로컬 PTY, 원격 holder, tmux)이 바뀌어도 이 모양은 그대로다.
///
/// 이진 분할 트리다. 같은 방향으로 셋 이상 나란히 둘 때도 둘씩 중첩한다(tmux와 같다).
indirect enum PaneLayout: Codable, Equatable {
    /// 터미널 하나. id는 패널 id이자 그 터미널의 `SM_PANE_ID`다.
    case pane(UUID)
    /// `first`가 왼쪽(가로) 또는 위(세로). ratio는 first가 차지하는 몫이다.
    case split(PaneAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    /// 화면 순서(왼쪽 위부터)대로의 패널 id.
    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    var paneCount: Int { paneIDs.count }

    func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    /// `target`을 둘로 나눠 새 패널을 오른쪽(가로) 또는 아래(세로)에 둔다.
    func splitting(_ target: UUID, axis: PaneAxis, newPane: UUID) -> PaneLayout {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            return .split(axis, ratio: 0.5, first: .pane(id), second: .pane(newPane))
        case .split(let a, let ratio, let first, let second):
            return .split(a, ratio: ratio,
                          first: first.splitting(target, axis: axis, newPane: newPane),
                          second: second.splitting(target, axis: axis, newPane: newPane))
        }
    }

    /// `target`을 뺀 배치. 형제가 그 자리를 다 차지한다. 마지막 패널이면 nil.
    func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let left = first.removing(target)
            let right = second.removing(target)
            switch (left, right) {
            case let (l?, r?): return .split(axis, ratio: ratio, first: l, second: r)
            case let (l?, nil): return l
            case let (nil, r?): return r
            case (nil, nil): return nil
            }
        }
    }

    /// 분할 노드 하나의 비율을 바꾼다. `path`는 루트에서 그 노드까지의 갈림(false=first).
    func settingRatio(_ ratio: Double, at path: [Bool]) -> PaneLayout {
        guard case .split(let axis, let current, let first, let second) = self else { return self }
        guard let step = path.first else {
            return .split(axis, ratio: Self.clamp(ratio), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis, ratio: current, first: first, second: second.settingRatio(ratio, at: rest))
            : .split(axis, ratio: current, first: first.settingRatio(ratio, at: rest), second: second)
    }

    /// 한 패널이 너무 얇아져 프롬프트 한 줄도 못 담는 일을 막는다.
    static func clamp(_ ratio: Double) -> Double { min(0.85, max(0.15, ratio)) }

    /// 각 패널이 `rect` 안에서 차지하는 영역. 사이 선(`divider`) 두께만큼 비워 둔다.
    func frames(in rect: CGRect, divider: CGFloat = 0) -> [UUID: CGRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio, divider: divider)
            return first.frames(in: a, divider: divider)
                .merging(second.frames(in: b, divider: divider)) { lhs, _ in lhs }
        }
    }

    /// 분할마다 사이 선 하나. 끌어서 비율을 바꿀 때 `container`와 `path`를 쓴다.
    func dividers(in rect: CGRect, divider: CGFloat, path: [Bool] = []) -> [PaneDivider] {
        guard case .split(let axis, let ratio, let first, let second) = self else { return [] }
        let (a, b) = Self.divide(rect, axis: axis, ratio: ratio, divider: divider)
        let line: CGRect = axis == .horizontal
            ? CGRect(x: a.maxX, y: rect.minY, width: divider, height: rect.height)
            : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: divider)
        return [PaneDivider(path: path, axis: axis, line: line, container: rect)]
            + first.dividers(in: a, divider: divider, path: path + [false])
            + second.dividers(in: b, divider: divider, path: path + [true])
    }

    static func divide(_ rect: CGRect, axis: PaneAxis, ratio: Double, divider: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let firstWidth = ((rect.width - divider) * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                    CGRect(x: rect.minX + firstWidth + divider, y: rect.minY,
                           width: rect.width - firstWidth - divider, height: rect.height))
        case .vertical:
            let firstHeight = ((rect.height - divider) * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                    CGRect(x: rect.minX, y: rect.minY + firstHeight + divider,
                           width: rect.width, height: rect.height - firstHeight - divider))
        }
    }

    /// 방향키로 옮겨 갈 이웃. 그 방향으로 맞닿은 패널 중 겹치는 길이가 가장 긴 것을 고른다.
    /// 좌표계는 위가 0이다(SwiftUI와 같다).
    func neighbor(of id: UUID, toward direction: PaneDirection) -> UUID? {
        let unit = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let frames = frames(in: unit)
        guard let origin = frames[id] else { return nil }
        let tolerance: CGFloat = 0.5
        func overlap(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat {
            max(0, min(a.1, b.1) - max(a.0, b.0))
        }
        let candidates = frames.compactMap { other, frame -> (UUID, CGFloat)? in
            guard other != id else { return nil }
            switch direction {
            case .left:
                guard abs(frame.maxX - origin.minX) <= tolerance else { return nil }
                return (other, overlap((frame.minY, frame.maxY), (origin.minY, origin.maxY)))
            case .right:
                guard abs(frame.minX - origin.maxX) <= tolerance else { return nil }
                return (other, overlap((frame.minY, frame.maxY), (origin.minY, origin.maxY)))
            case .up:
                guard abs(frame.maxY - origin.minY) <= tolerance else { return nil }
                return (other, overlap((frame.minX, frame.maxX), (origin.minX, origin.maxX)))
            case .down:
                guard abs(frame.minY - origin.maxY) <= tolerance else { return nil }
                return (other, overlap((frame.minX, frame.maxX), (origin.minX, origin.maxX)))
            }
        }
        return candidates.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }
}

enum PaneAxis: String, Codable {
    /// 좌우로 나란히
    case horizontal
    /// 위아래로 쌓기
    case vertical
}

enum PaneDirection {
    case left, right, up, down
}

struct PaneDivider: Equatable {
    let path: [Bool]
    let axis: PaneAxis
    let line: CGRect
    let container: CGRect

    /// 끄는 지점(같은 좌표계)에서 그 분할의 새 비율.
    func ratio(at point: CGPoint, divider: CGFloat) -> Double {
        switch axis {
        case .horizontal:
            return Double((point.x - container.minX - divider / 2) / max(1, container.width - divider))
        case .vertical:
            return Double((point.y - container.minY - divider / 2) / max(1, container.height - divider))
        }
    }
}
