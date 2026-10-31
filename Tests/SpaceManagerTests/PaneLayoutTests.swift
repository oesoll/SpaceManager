import XCTest
@testable import SpaceManager

final class PaneLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    /// a | (b / c) — tmux에서 오른쪽 패널을 위아래로 나눈 흔한 배치.
    private var threePanes: PaneLayout {
        PaneLayout.pane(a)
            .splitting(a, axis: .horizontal, newPane: b)
            .splitting(b, axis: .vertical, newPane: c)
    }

    func testSplitPlacesNewPaneAfterTarget() {
        XCTAssertEqual(threePanes.paneIDs, [a, b, c])
        XCTAssertEqual(threePanes,
                       .split(.horizontal, ratio: 0.5, first: .pane(a),
                              second: .split(.vertical, ratio: 0.5, first: .pane(b), second: .pane(c))))
    }

    func testRemovingLetsSiblingTakeTheSpace() {
        XCTAssertEqual(threePanes.removing(b),
                       .split(.horizontal, ratio: 0.5, first: .pane(a), second: .pane(c)))
        XCTAssertEqual(PaneLayout.pane(a).removing(a), nil)
        XCTAssertEqual(threePanes.removing(UUID()), threePanes)
    }

    func testFramesLeaveRoomForDividers() {
        let frames = threePanes.frames(in: CGRect(x: 0, y: 0, width: 201, height: 101), divider: 1)
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 100, height: 101))
        XCTAssertEqual(frames[b], CGRect(x: 101, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames[c], CGRect(x: 101, y: 51, width: 100, height: 50))
    }

    func testDividerDragMapsPointerToRatio() {
        let rect = CGRect(x: 0, y: 0, width: 201, height: 101)
        let dividers = threePanes.dividers(in: rect, divider: 1)
        XCTAssertEqual(dividers.count, 2)
        XCTAssertEqual(dividers[0].path, [])
        XCTAssertEqual(dividers[0].line, CGRect(x: 100, y: 0, width: 1, height: 101))
        XCTAssertEqual(dividers[1].path, [true])
        // 포인터가 선 한가운데에 있으면 비율이 그대로다.
        XCTAssertEqual(dividers[0].ratio(at: CGPoint(x: 100.5, y: 10), divider: 1), 0.5, accuracy: 0.001)
        let moved = threePanes.settingRatio(dividers[0].ratio(at: CGPoint(x: 150.5, y: 0), divider: 1), at: [])
        XCTAssertEqual(moved.frames(in: rect, divider: 1)[a]?.width, 150)
        // 오른쪽 안의 위아래 분할만 바뀌고 바깥 비율은 그대로다.
        let inner = threePanes.settingRatio(0.25, at: [true])
        guard case .split(_, let outer, _, .split(_, let ratio, _, _)) = inner else { return XCTFail() }
        XCTAssertEqual(outer, 0.5)
        XCTAssertEqual(ratio, 0.25)
    }

    func testRatioIsClampedSoNoPaneDisappears() {
        let squeezed = threePanes.settingRatio(0.01, at: [])
        guard case .split(_, let ratio, _, _) = squeezed else { return XCTFail() }
        XCTAssertEqual(ratio, 0.15)
    }

    func testNeighborFollowsGeometry() {
        XCTAssertNotNil(threePanes.neighbor(of: a, toward: .right))
        XCTAssertEqual(threePanes.neighbor(of: b, toward: .down), c)
        XCTAssertEqual(threePanes.neighbor(of: c, toward: .up), b)
        XCTAssertEqual(threePanes.neighbor(of: c, toward: .left), a)
        XCTAssertNil(threePanes.neighbor(of: a, toward: .left))
        // 오른쪽 위를 크게 만들면 a의 오른쪽 이웃은 더 많이 맞닿은 b다.
        let tallTop = threePanes.settingRatio(0.8, at: [true])
        XCTAssertEqual(tallTop.neighbor(of: a, toward: .right), b)
        let tallBottom = threePanes.settingRatio(0.2, at: [true])
        XCTAssertEqual(tallBottom.neighbor(of: a, toward: .right), c)
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(threePanes)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayout.self, from: data), threePanes)
    }
}
