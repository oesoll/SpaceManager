import Foundation
import CoreGraphics

/// 워크스페이스 하나의 배치(탭·패널) — 세션 층이 그 워크스페이스가 사는 기기에 두는 데이터
/// (`~/.smux/state/sm/workspaces/<ws>.json`, 10/31 계약). tmux 서버가 갖던 창·분할을 데이터로 옮긴 것이다.
/// 앱은 이것을 그릴 뿐이고, 바꿀 때는 `sm-session` 명령을 부른다 — 에이전트도 같은 명령을 쓴다.
struct WorkspaceLayout: Decodable, Equatable {
    let workspace: String
    let host: String
    let cwd: String
    let version: Int
    let activeTab: String?
    let tabs: [Tab]
    let panes: [String: Pane]

    enum CodingKeys: String, CodingKey {
        case workspace, host, cwd, version, tabs, panes
        case activeTab = "active_tab"
    }

    struct Tab: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let focus: String?
        let zoom: String?
        let root: LayoutNode
    }

    struct Pane: Decodable, Equatable {
        /// 이 패널이 보여 주는 세션(sm 이름). 이름이 곧 세션이다. nil이면 셸 패널.
        let session: String?
        let shell: Bool
        /// 아직 tmux 안에서 도는 에이전트의 tmux 칸(옮기기 전).
        let tmuxPane: String?

        enum CodingKeys: String, CodingKey {
            case session, shell
            case tmuxPane = "tmux_pane"
        }

        init(session: String?, shell: Bool = false, tmuxPane: String? = nil) {
            self.session = session
            self.shell = shell
            self.tmuxPane = tmuxPane
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            session = try c.decodeIfPresent(String.self, forKey: .session)
            shell = try c.decodeIfPresent(Bool.self, forKey: .shell) ?? (session == nil)
            tmuxPane = try c.decodeIfPresent(String.self, forKey: .tmuxPane)
        }
    }

    var currentTab: Tab? {
        tabs.first { $0.id == activeTab } ?? tabs.first
    }

    func tab(containing pane: String) -> Tab? {
        tabs.first { $0.root.paneIDs.contains(pane) }
    }

    static func decode(_ data: Data) throws -> WorkspaceLayout {
        try JSONDecoder().decode(WorkspaceLayout.self, from: data)
    }
}

/// 분할 트리. 잎은 패널 하나, 가지는 같은 방향으로 나란한 자식들(크기 합 1).
/// `row`는 좌우로 나란히(tmux split -h), `col`은 위아래로 쌓기.
indirect enum LayoutNode: Decodable, Equatable {
    case pane(id: String, size: Double)
    case split(dir: Direction, children: [LayoutNode], size: Double)

    enum Direction: String, Decodable { case row, col }

    private enum CodingKeys: String, CodingKey { case pane, dir, children, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        if let id = try c.decodeIfPresent(String.self, forKey: .pane) {
            self = .pane(id: id, size: size)
        } else {
            self = .split(dir: try c.decode(Direction.self, forKey: .dir),
                          children: try c.decode([LayoutNode].self, forKey: .children), size: size)
        }
    }

    var size: Double {
        switch self {
        case .pane(_, let size), .split(_, _, let size): return size
        }
    }

    /// 화면 순서(왼쪽 위부터)의 패널 id.
    var paneIDs: [String] {
        switch self {
        case .pane(let id, _): return [id]
        case .split(_, let children, _): return children.flatMap(\.paneIDs)
        }
    }

    /// 자식 영역. 크기는 합이 1이 아니어도 비율로 나눈다(쓰는 중간에 읽어도 그릴 수 있게).
    static func divide(_ rect: CGRect, dir: Direction, sizes: [Double], gap: CGFloat) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let total = max(sizes.reduce(0, +), 0.0001)
        let length = (dir == .row ? rect.width : rect.height) - gap * CGFloat(sizes.count - 1)
        var offset: CGFloat = dir == .row ? rect.minX : rect.minY
        var frames: [CGRect] = []
        for (index, size) in sizes.enumerated() {
            let isLast = index == sizes.count - 1
            let end = dir == .row ? rect.maxX : rect.maxY
            let extent = isLast ? end - offset : (length * CGFloat(size / total)).rounded()
            frames.append(dir == .row
                ? CGRect(x: offset, y: rect.minY, width: extent, height: rect.height)
                : CGRect(x: rect.minX, y: offset, width: rect.width, height: extent))
            offset += extent + gap
        }
        return frames
    }

    func frames(in rect: CGRect, gap: CGFloat) -> [String: CGRect] {
        switch self {
        case .pane(let id, _):
            return [id: rect]
        case .split(let dir, let children, _):
            let parts = Self.divide(rect, dir: dir, sizes: children.map(\.size), gap: gap)
            var result: [String: CGRect] = [:]
            for (child, part) in zip(children, parts) {
                result.merge(child.frames(in: part, gap: gap)) { lhs, _ in lhs }
            }
            return result
        }
    }

    /// 자식 사이의 경계선마다 하나. 끌면 그 선 양쪽 두 칸의 몫만 바뀐다.
    func boundaries(in rect: CGRect, gap: CGFloat, path: [Int] = []) -> [LayoutBoundary] {
        guard case .split(let dir, let children, _) = self else { return [] }
        let parts = Self.divide(rect, dir: dir, sizes: children.map(\.size), gap: gap)
        var result: [LayoutBoundary] = []
        for index in 0..<max(0, children.count - 1) {
            let before = parts[index], after = parts[index + 1]
            let line = dir == .row
                ? CGRect(x: before.maxX, y: rect.minY, width: after.minX - before.maxX, height: rect.height)
                : CGRect(x: rect.minX, y: before.maxY, width: rect.width, height: after.minY - before.maxY)
            result.append(LayoutBoundary(path: path, index: index, dir: dir, line: line, container: rect,
                                         sizes: children.map(\.size),
                                         leadingPane: children[index].paneIDs.first ?? "",
                                         trailingPane: children[index + 1].paneIDs.first ?? ""))
        }
        for (index, (child, part)) in zip(children, parts).enumerated() {
            result += child.boundaries(in: part, gap: gap, path: path + [index])
        }
        return result
    }

    /// 경계선을 끄는 동안의 미리보기: `path`의 가지에서 index와 index+1의 몫만 바꾼다.
    func resizing(path: [Int], sizes newSizes: [Double]) -> LayoutNode {
        guard case .split(let dir, let children, let size) = self else { return self }
        guard let step = path.first else {
            let rebuilt = zip(children, newSizes).map { child, value in child.withSize(value) }
            return .split(dir: dir, children: rebuilt, size: size)
        }
        var next = children
        next[step] = children[step].resizing(path: Array(path.dropFirst()), sizes: newSizes)
        return .split(dir: dir, children: next, size: size)
    }

    /// 이 자식의 몫을 바꾸라고 명령에 넘길 패널. 세션 층은 그 패널에서 위로 올라가 처음 만나는
    /// 같은 방향 가지의 몫을 바꾸므로, 중간에 같은 방향 가지가 끼지 않은 패널이어야 한다.
    func resizeTarget(crossing dir: Direction) -> String? {
        switch self {
        case .pane(let id, _): return id
        case .split(let childDir, let children, _):
            guard childDir != dir else { return nil }
            return children.lazy.compactMap { $0.resizeTarget(crossing: dir) }.first
        }
    }

    func child(at path: [Int]) -> LayoutNode? {
        guard let step = path.first else { return self }
        guard case .split(_, let children, _) = self, children.indices.contains(step) else { return nil }
        return children[step].child(at: Array(path.dropFirst()))
    }

    func withSize(_ value: Double) -> LayoutNode {
        switch self {
        case .pane(let id, _): return .pane(id: id, size: value)
        case .split(let dir, let children, _): return .split(dir: dir, children: children, size: value)
        }
    }

    /// 포커스된 잎 옆에 아직 데이터에 없는 자리를 끼운 미리보기(고르는 상자용).
    /// 부모가 같은 방향이면 그 줄에 끼우고(그 칸의 몫을 반으로), 아니면 그 잎을 둘로 나눈다.
    func inserting(_ newPane: String, beside target: String, dir: Direction, after: Bool = true) -> LayoutNode {
        switch self {
        case .pane(let id, let size):
            guard id == target else { return self }
            let pair: [LayoutNode] = after
                ? [.pane(id: id, size: 0.5), .pane(id: newPane, size: 0.5)]
                : [.pane(id: newPane, size: 0.5), .pane(id: id, size: 0.5)]
            return .split(dir: dir, children: pair, size: size)
        case .split(let childDir, let children, let size):
            if childDir == dir, let index = children.firstIndex(where: {
                if case .pane(let id, _) = $0 { return id == target }
                return false
            }) {
                var next = children
                let half = children[index].size / 2
                next[index] = children[index].withSize(half)
                next.insert(.pane(id: newPane, size: half), at: after ? index + 1 : index)
                return .split(dir: childDir, children: next, size: size)
            }
            return .split(dir: childDir, children: children.map { $0.inserting(newPane, beside: target, dir: dir, after: after) },
                          size: size)
        }
    }
}

struct LayoutBoundary: Equatable {
    /// 루트에서 이 경계선을 가진 가지까지의 자식 번호.
    let path: [Int]
    /// 경계선 왼쪽(위)의 자식 번호.
    let index: Int
    let dir: LayoutNode.Direction
    let line: CGRect
    let container: CGRect
    let sizes: [Double]
    /// 몫을 바꿀 때 명령에 넘길 패널(그 자식 안의 첫 패널).
    let leadingPane: String
    let trailingPane: String

    /// 끄는 지점에서 새 몫. index와 index+1만 바뀌고 둘의 합은 그대로다. 한쪽이 너무 얇아지지 않게 막는다.
    func sizes(at point: CGPoint, gap: CGFloat) -> [Double] {
        let total = sizes.reduce(0, +)
        let pair = sizes[index] + sizes[index + 1]
        let length = (dir == .row ? container.width : container.height) - gap * CGFloat(sizes.count - 1)
        guard length > 0, total > 0 else { return sizes }
        let start = dir == .row ? container.minX : container.minY
        let leadingStart = start + length * CGFloat(sizes[..<index].reduce(0, +) / total) + gap * CGFloat(index)
        let position = (dir == .row ? point.x : point.y) - leadingStart - gap / 2
        let minimum = 0.05 * total
        let leading = min(max(Double(position / length) * total, minimum), pair - minimum)
        var next = sizes
        next[index] = leading
        next[index + 1] = pair - leading
        return next
    }
}
