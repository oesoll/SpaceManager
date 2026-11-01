import AppKit
import XCTest
@testable import SpaceManager

/// 메뉴 막대 아이콘: sm이 앞에 있고 키 창이 sm 작업 창일 때만 숨기고, 그 밖에는(숨겨졌거나 다른 앱 뒤에 깔렸거나
/// 창이 없거나) 보인다 — agentOS 메뉴 막대와 같은 규칙.
@MainActor
final class StatusBarToggleTests: XCTestCase {
    func testHidesOnlyWhenSmIsInFront() {
        XCTAssertEqual(StatusBarToggle.action(isHidden: false, isActive: true, keyIsWorkWindow: true), .hide)
        XCTAssertEqual(StatusBarToggle.action(isHidden: false, isActive: false, keyIsWorkWindow: true), .show,
                       "behind another app: bring it forward, not hide")
        XCTAssertEqual(StatusBarToggle.action(isHidden: true, isActive: false, keyIsWorkWindow: false), .show)
        XCTAssertEqual(StatusBarToggle.action(isHidden: false, isActive: true, keyIsWorkWindow: false), .show,
                       "active with no work window in front (only the notch): show the windows")
    }

    func testGlyphIsAMenuBarTemplate() {
        let glyph = StatusBarToggle.glyph()
        XCTAssertTrue(glyph.isTemplate)
        XCTAssertEqual(glyph.size, NSSize(width: 18, height: 18))
    }
}
