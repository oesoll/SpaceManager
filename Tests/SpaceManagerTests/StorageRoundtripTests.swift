import XCTest
@testable import SpaceManager

final class StorageRoundtripTests: XCTestCase {
    func testWindowStateRoundtrip() throws {
        let wsId = UUID()
        let state = WindowState(
            id: UUID(),
            selectedWorkspaceId: wsId,
            workspaces: [Workspace(id: wsId, rootPath: "/tmp/work", layoutName: "work")],
            frame: WindowFrameState(x: 120, y: 80, width: 1440, height: 900),
            isZoomed: true,
            isFullscreen: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WindowState].self, from: encoder.encode([state]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, state.id)
        XCTAssertTrue(decoded[0].isWorkspaceWindow)
        XCTAssertEqual(decoded[0].workspaces?.first?.layoutName, "work")
        XCTAssertEqual(decoded[0].frame, state.frame)
        XCTAssertTrue(decoded[0].resolvedIsZoomed)
        XCTAssertFalse(decoded[0].resolvedIsFullscreen)
    }

    /// 배치 이름은 예전 키("tmuxSessionName")로 저장한다 — 지금까지의 window-states.json을 그대로 읽는다.
    func testLayoutNameKeepsTheOldStorageKey() throws {
        let json = """
        {"id":"\(UUID().uuidString)","rootPath":"/tmp/x","additionalProjects":[],"tmuxSessionName":"flat",
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ws = try decoder.decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(ws.layoutName, "flat")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try JSONSerialization.jsonObject(with: encoder.encode(ws)) as? [String: Any]
        XCTAssertEqual(back?["tmuxSessionName"] as? String, "flat")
    }

    func testWorkspaceDecodesLegacyJSONWithoutNewFields() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","rootPath":"/tmp/x","additionalProjects":[],
         "orchestratorEnabled":true,
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ws = try decoder.decode(Workspace.self, from: Data(legacy.utf8))
        XCTAssertEqual(ws.name, "x")
        XCTAssertNil(ws.layoutName)   // 구 파일 호환: 새 필드 없어도 로드됨
    }

    /// tmux 탭 시절의 상태(workspaceTabs, kind)도 그대로 읽힌다. 탭 목록은 버린다 — 탭은 세션 층 배치가 원본이다.
    func testWindowStateDecodesLegacyJSON() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","selectedWorkspaceId":null,"kind":"workspace",
         "workspaceTabs":[{"workspaceId":"\(UUID().uuidString)","tabs":[{"id":"\(UUID().uuidString)","kind":"tmuxMain",
         "name":"work","workingDirectory":"/tmp"}]}]}
        """
        let state = try JSONDecoder().decode(WindowState.self, from: Data(legacy.utf8))
        XCTAssertNil(state.workspaces)   // 레거시 상태 → 전역 목록 폴백 트리거
        XCTAssertTrue(state.isWorkspaceWindow)
        XCTAssertNil(state.frame)
        XCTAssertFalse(state.resolvedIsZoomed)
        XCTAssertFalse(state.resolvedIsFullscreen)
    }

    /// 없앤 Quick 창의 상태는 작업 창으로 복원하지 않는다.
    func testQuickWindowStateIsNotAWorkspaceWindow() throws {
        let quick = try JSONDecoder().decode(WindowState.self, from: Data("""
        {"id":"\(UUID().uuidString)","kind":"quick","selectedWorkspaceId":null,"workspaceTabs":[],"appearance":"light"}
        """.utf8))
        XCTAssertFalse(quick.isWorkspaceWindow)
    }

    func testExactWindowClaimIgnoresSavedArrayOrder() throws {
        let kmongID = UUID()
        let vthID = UUID()
        let kmongWorkspaceID = UUID()
        let vthWorkspaceID = UUID()
        let states = [
            WindowState(id: vthID, selectedWorkspaceId: vthWorkspaceID),
            WindowState(id: kmongID, selectedWorkspaceId: kmongWorkspaceID)
        ]

        let claimed = try XCTUnwrap(WorkspaceStorage.exactUnclaimedState(
            id: kmongID,
            states: states,
            claimedIDs: []
        ))
        XCTAssertEqual(claimed.id, kmongID)
        XCTAssertEqual(claimed.selectedWorkspaceId, kmongWorkspaceID)
        XCTAssertNil(WorkspaceStorage.exactUnclaimedState(
            id: kmongID,
            states: states,
            claimedIDs: [kmongID]
        ))
    }

    func testExplicitlyEmptyWorkspaceStateIsNotRestored() {
        let empty = WindowState(id: UUID(), selectedWorkspaceId: nil, workspaces: [])
        let legacy = WindowState(id: UUID(), selectedWorkspaceId: nil, workspaces: nil)
        XCTAssertTrue(WorkspaceStorage.isDiscardableEmptyWorkspaceState(empty))
        XCTAssertFalse(WorkspaceStorage.isDiscardableEmptyWorkspaceState(legacy))
    }
}
