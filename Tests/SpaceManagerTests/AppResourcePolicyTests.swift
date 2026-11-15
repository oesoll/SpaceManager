import XCTest
@testable import SpaceManager

final class AppResourcePolicyTests: XCTestCase {
    func testBackgroundVisibleWindowStillUpdatesButCoveredAndMinimizedWindowsDoNot() {
        XCTAssertTrue(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: false, isOccluded: false))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: true, isOccluded: false))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: true, isMiniaturized: false, isOccluded: true))
        XCTAssertFalse(AppResourcePolicy.isVisible(isVisible: false, isMiniaturized: false, isOccluded: false))
    }

    func testClosingOneWindowKeepsSharedScannersAliveUntilLastConsumerLeaves() {
        let first = UUID(), second = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activity = RecentActivityScanner(projectsDir: directory,
            codexSessionsDir: directory, geminiDir: directory)
        activity.start(owner: first)
        activity.start(owner: second)
        activity.stop(owner: first)
        XCTAssertTrue(activity.isStarted)
        activity.stop(owner: second)
        XCTAssertFalse(activity.isStarted)
    }
}
