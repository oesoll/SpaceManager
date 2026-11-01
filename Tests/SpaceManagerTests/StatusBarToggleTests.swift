import AppKit
import XCTest
@testable import SpaceManager

/// 메뉴 막대 아이콘: 한 번 누르면 작업 창을 전부 숨기고(노치 같은 패널은 그대로), 다시 누르면 숨기기 전 겹친
/// 순서 그대로 되돌린다.
@MainActor
final class StatusBarToggleTests: XCTestCase {
    func testHidesWorkWindowsButNotPanelsAndRestoresTheirOrder() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        func window(_ title: String) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            return window
        }
        let back = window("back"), front = window("front")
        let notch = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 50, height: 20), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        defer { back.close(); front.close(); notch.close() }
        back.orderFront(nil); front.orderFront(nil); notch.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let toggle = StatusBarToggle()
        toggle.toggle()
        XCTAssertFalse(back.isVisible); XCTAssertFalse(front.isVisible)
        XCTAssertTrue(notch.isVisible, "the notch must stay")
        XCTAssertTrue(toggle.isHiding)

        toggle.toggle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(back.isVisible); XCTAssertTrue(front.isVisible)
        XCTAssertFalse(toggle.isHiding)
        let order = NSApp.orderedWindows.filter { $0 === back || $0 === front }
        XCTAssertEqual(order.first, front, "the window that was in front comes back in front")
    }
}
