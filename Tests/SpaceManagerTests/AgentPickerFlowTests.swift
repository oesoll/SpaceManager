import XCTest
@testable import SpaceManager

final class AgentPickerFlowTests: XCTestCase {
    private func tab() -> TerminalSession {
        TerminalSession(kind: .shell, name: "zsh", workingDirectory: "/tmp")
    }

    /// ⌘D는 자리를 만들고 상자를 띄운다. 취소하면 흔적 없이 사라지고 포커스는 원래 패널로 돌아간다.
    func testCancelLeavesNoTrace() {
        let anchor = tab()
        let group = PaneGroup(anchor: anchor)
        let before = group.layout
        let id = group.splitForPicker(.horizontal)
        XCTAssertTrue(group.picking.contains(id))
        XCTAssertEqual(group.focused, id)
        XCTAssertNil(group.session(for: id), "고르기 전에는 터미널이 없다")
        group.cancelPicker(id)
        XCTAssertEqual(group.layout, before)
        XCTAssertEqual(group.focused, anchor.id)
        XCTAssertTrue(group.picking.isEmpty)
    }

    /// 고르면 그 자리에 터미널이 붙는다(같은 자리, 같은 id).
    func testResolveAttachesInPlace() {
        let group = PaneGroup(anchor: tab())
        let id = group.splitForPicker(.vertical)
        let session = TerminalSession(id: id, kind: .shell, name: "flat-claude-1", workingDirectory: "/tmp",
                                      attachment: .agent(name: "flat-claude-1", host: "mac", agent: nil))
        group.resolvePicker(id, with: session)
        XCTAssertFalse(group.picking.contains(id))
        XCTAssertTrue(group.session(for: id) === session)
        XCTAssertEqual(group.layout.paneIDs.last, id)
    }

    /// 모델·effort는 엔진의 래퍼가 받는 모양으로, 세션은 이 패널에 묶여 뜬다.
    func testSpawnArgumentsFollowEachWrapper() {
        let claude = AgentLaunchSpec(engine: .claude, modelID: "claude-opus-5-5", effort: .high, name: "flat-claude-1")
        XCTAssertEqual(SessionLayer.spawnArguments(claude, pane: "P", workingDirectory: "/w"),
                       ["spawn", "flat-claude-1", "--kind", "claude", "--cwd", "/w", "--pane", "P",
                        "--", "--model", "claude-opus-5-5", "--effort", "high"])
        let codex = AgentLaunchSpec(engine: .codex, modelID: "gpt-6.1-sol", effort: .xhigh, name: "flat-codex-1")
        XCTAssertEqual(SessionLayer.spawnArguments(codex, pane: nil, workingDirectory: "~/flat", host: "arch"),
                       ["spawn", "flat-codex-1", "--kind", "codex", "--cwd", "~/flat", "--host", "arch",
                        "--", "-m", "gpt-6.1-sol", "-c", "model_reasoning_effort=xhigh"])
    }

    func testCodexModelsComeFromTheVisibleCacheEntries() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString).json")
        try """
        {"models": [
          {"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "default_reasoning_level": "low",
           "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]},
          {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide"}
        ]}
        """.write(to: cache, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cache) }
        let models = AgentModelCatalog.codex(cache: cache)
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol"])
        XCTAssertEqual(models.first?.efforts, [.low, .high])
        XCTAssertEqual(models.first?.defaultEffort, .low)
    }
}
