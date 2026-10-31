import XCTest
@testable import SpaceManager

final class WorkspaceLayoutTests: XCTestCase {
    /// 세션 층이 실제로 쓰는 모양(10/31 saengjon.json을 줄였다).
    private let sample = """
    {"schema": 1, "workspace": "saengjon", "host": "mac", "cwd": "/w", "version": 4, "active_tab": "t-2",
     "tabs": [{"id": "t-1", "name": "lead", "focus": "p-1", "zoom": null, "root": {"pane": "p-1"}},
              {"id": "t-2", "name": "workers", "focus": "p-3", "zoom": null,
               "root": {"dir": "row", "children": [{"pane": "p-2", "size": 0.5},
                        {"dir": "col", "size": 0.5, "children": [{"pane": "p-3", "size": 0.25}, {"pane": "p-4", "size": 0.75}]}]}}],
     "panes": {"p-1": {"session": "inche-lead", "shell": false, "tmux_pane": "%4"},
               "p-2": {"session": "inche-script", "shell": false}, "p-3": {"session": null, "shell": true},
               "p-4": {"session": "inche-video"}},
     "adopted_from": "tmux:saengjon"}
    """

    func testDecodesTheSessionLayerFile() throws {
        let layout = try WorkspaceLayout.decode(Data(sample.utf8))
        XCTAssertEqual(layout.version, 4)
        XCTAssertEqual(layout.currentTab?.name, "workers")
        XCTAssertEqual(layout.currentTab?.root.paneIDs, ["p-2", "p-3", "p-4"])
        XCTAssertEqual(layout.panes["p-1"]?.tmuxPane, "%4")
        XCTAssertEqual(layout.panes["p-3"]?.shell, true)
        XCTAssertEqual(layout.panes["p-4"]?.shell, false, "세션이 있으면 셸이 아니다")
        XCTAssertEqual(layout.tab(containing: "p-1")?.id, "t-1")
    }

    func testFramesFollowSizesWithGaps() throws {
        let root = try XCTUnwrap(WorkspaceLayout.decode(Data(sample.utf8)).currentTab?.root)
        let frames = root.frames(in: CGRect(x: 0, y: 0, width: 208, height: 108), gap: 8)
        XCTAssertEqual(frames["p-2"], CGRect(x: 0, y: 0, width: 100, height: 108))
        XCTAssertEqual(frames["p-3"], CGRect(x: 108, y: 0, width: 100, height: 25))
        XCTAssertEqual(frames["p-4"], CGRect(x: 108, y: 33, width: 100, height: 75))
    }

    /// 경계선을 끌면 그 선 양쪽 두 칸만 바뀌고, 둘 다 너무 얇아지지 않는다(세션 층의 --toward와 같다).
    func testBoundaryDragChangesOnlyTheTwoNeighbours() {
        let row = LayoutNode.split(dir: .row, children: [.pane(id: "a", size: 0.25), .pane(id: "b", size: 0.25), .pane(id: "c", size: 0.5)], size: 1)
        let rect = CGRect(x: 0, y: 0, width: 416, height: 100)
        let boundaries = row.boundaries(in: rect, gap: 8)
        XCTAssertEqual(boundaries.count, 2)
        let between = boundaries[0]
        XCTAssertEqual(between.leadingPane, "a")
        let sizes = between.sizes(at: CGPoint(x: 154, y: 50), gap: 8)
        XCTAssertEqual(sizes[0], 0.375, accuracy: 0.001)
        XCTAssertEqual(sizes[1], 0.125, accuracy: 0.001)
        XCTAssertEqual(sizes[2], 0.5)
        let squeezed = between.sizes(at: CGPoint(x: 400, y: 50), gap: 8)
        XCTAssertEqual(squeezed[1], 0.05, accuracy: 0.001)
    }

    /// 명령에 넘길 패널은 그 경계의 줄에 바로 닿아야 한다 — 같은 방향 가지 안이면 다른 줄을 바꾼다.
    func testResizeTargetSkipsNestedSameDirectionBranches() {
        let nestedRow = LayoutNode.split(dir: .row, children: [.pane(id: "x", size: 0.5), .pane(id: "y", size: 0.5)], size: 0.5)
        XCTAssertNil(nestedRow.resizeTarget(crossing: .row))
        let column = LayoutNode.split(dir: .col, children: [nestedRow, .pane(id: "z", size: 0.5)], size: 0.5)
        XCTAssertEqual(column.resizeTarget(crossing: .row), "z")
        XCTAssertEqual(LayoutNode.pane(id: "p", size: 1).resizeTarget(crossing: .col), "p")
    }

    /// 고르는 상자 자리: 같은 방향 줄이면 그 줄에 끼우고, 아니면 그 잎을 둘로 나눈다.
    func testPendingPaneIsInsertedBesideTheFocusedPane() {
        let row = LayoutNode.split(dir: .row, children: [.pane(id: "a", size: 0.5), .pane(id: "b", size: 0.5)], size: 1)
        XCTAssertEqual(row.inserting("n", beside: "a", dir: .row).paneIDs, ["a", "n", "b"])
        guard case .split(.row, let children, _) = row.inserting("n", beside: "a", dir: .row) else { return XCTFail() }
        XCTAssertEqual(children.map(\.size), [0.25, 0.25, 0.5])
        let down = row.inserting("n", beside: "b", dir: .col)
        XCTAssertEqual(down.paneIDs, ["a", "b", "n"])
        guard case .split(.row, let outer, _) = down, case .split(.col, _, let size) = outer[1] else { return XCTFail() }
        XCTAssertEqual(size, 0.5)
    }
}
