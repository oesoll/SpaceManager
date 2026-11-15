import XCTest
@testable import SpaceManager

final class AgentPickerFlowTests: XCTestCase {
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
