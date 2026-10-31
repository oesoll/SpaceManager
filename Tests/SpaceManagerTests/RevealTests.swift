import XCTest
@testable import SpaceManager

/// `sm reveal`: Fine 노치에서 누른 에이전트가 보이는 패널로 간다 — 다른 탭에 있으면 그 탭까지,
/// 이름의 대소문자가 달라도(Fine은 소문자로 저장한다), 어느 패널에도 없으면 새 탭에 붙인다.
final class RevealTests: XCTestCase {
    private static var window: AppState?
    private var appState: AppState!
    private var workspace: Workspace!
    private var key = ""

    override func setUpWithError() throws {
        // 세션 층의 배치 폴더에 쓴다 — 실제 홈이면 SEOL의 배치를 덮는다.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try XCTSkipIf(home.standardizedFileURL == realHome.standardizedFileURL, "run through scripts/test-isolated.sh")

        let dir = home.appendingPathComponent("work/flat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = home.appendingPathComponent(".space-manager")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Workspace(rootPath: dir.path)]).write(to: storage.appendingPathComponent("workspaces.json"))

        let host = PeerDirectory.shared.localHostName
        let folder = home.appendingPathComponent(".smux/state/sm/workspaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"workspace": "flat", "host": "\(host)", "cwd": "\(dir.path)", "version": 1, "active_tab": "t-main",
         "tabs": [{"id": "t-main", "name": "main", "focus": "p-a", "root": {"pane": "p-a"}},
                  {"id": "t-eng", "name": "engine", "focus": "p-c",
                   "root": {"dir": "row", "children": [{"pane": "p-c", "size": 0.5}, {"pane": "p-d", "size": 0.5}]}}],
         "panes": {"p-a": {"session": "flat-main"}, "p-c": {"session": "flat-sol"}, "p-d": {"session": "Habitrend-hoopoe"}}}
        """.write(to: folder.appendingPathComponent("flat.json"), atomically: true, encoding: .utf8)

        // 창 하나가 워크스페이스를 가져가면 다음 창에는 없다(저장소가 프로세스에 하나) — 시험들이 한 창을 같이 쓴다.
        if Self.window == nil { Self.window = AppState(windowKind: .workspace) }
        appState = Self.window
        workspace = try XCTUnwrap(appState.workspaces.first { $0.name == "flat" })
        appState.layoutInteraction.focusOverride = nil
        appState.layoutInteraction.activeTabOverride = nil
        key = LayoutDirectory.key(workspace: "flat", host: host)
        LayoutDirectory.shared.reloadLocal()
        let deadline = Date().addingTimeInterval(3)
        while LayoutDirectory.shared.layouts[key] == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        _ = try XCTUnwrap(LayoutDirectory.shared.layouts[key], "layout file was not read")
    }

    private func reveal(_ name: String, pane: String? = nil) -> Result<(tab: String, pane: String), SessionLayer.Failure>? {
        var outcome: Result<(tab: String, pane: String), SessionLayer.Failure>?
        appState.reveal(session: name, in: workspace, layoutKey: key, pane: pane) { outcome = $0 }
        let deadline = Date().addingTimeInterval(10)
        while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return outcome
    }

    func testRevealGoesToThePaneInAnotherTabIgnoringCase() throws {
        let place = try XCTUnwrap(reveal("habitrend-hoopoe")).get()
        XCTAssertEqual(place.pane, "p-d")
        XCTAssertEqual(place.tab, "t-eng")
        XCTAssertEqual(appState.selectedWorkspace?.id, workspace.id)
        XCTAssertEqual(appState.layoutInteraction.focusOverride?.pane, "p-d")
        XCTAssertEqual(appState.layoutInteraction.activeTabOverride?.tab, "t-eng", "the pane's tab comes to the front")
    }

    func testRevealPrefersThePaneTheSessionLayerNamed() throws {
        let place = try XCTUnwrap(reveal("flat-sol", pane: "p-c")).get()
        XCTAssertEqual(place.pane, "p-c")
    }

    /// 어느 패널에도 없으면 새 탭에 붙이려 한다. 이 격리 환경에는 세션 층이 없어 그 명령의 실패가 돌아온다.
    func testRevealOpensANewTabWhenNoPaneShowsIt() throws {
        let outcome = try XCTUnwrap(reveal("flat-ghost"))
        guard case .failure(let failure) = outcome else { return XCTFail("no pane shows flat-ghost, yet it was found") }
        XCTAssertTrue(failure.message.contains("sm-session"), failure.message)
    }
}
