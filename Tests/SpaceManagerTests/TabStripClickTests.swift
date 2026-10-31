import AppKit
import SwiftUI
import XCTest
@testable import SpaceManager

/// 탭 칩을 한 번 누르면 곧바로 골라져야 한다. 두 번 누르기(이름 바꾸기)와 한 번 누르기를 차례로 걸면
/// SwiftUI가 한 번 누른 것을 더블클릭 간격만큼 붙들어, 탭을 누를 때마다 늦었다(SEOL 10/31).
@MainActor
final class TabStripClickTests: XCTestCase {
    func testSingleClickSelectsWithoutWaitingForDoubleClick() throws {
        // 클릭이 SwiftUI 제스처까지 가려면 창이 화면에 떠 있어야 한다 — 다른 화면 시험처럼 따로 켠다.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        var selectedAt: Date?
        let strip = WorkspaceTabStrip(
            items: [.init(id: "t-eng", name: "engine", isActive: false)],
            onSelect: { _ in selectedAt = Date() },
            onRename: { _, _ in },
            onNew: {})
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: WorkspaceTabStrip.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: strip)
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKey()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let point = NSPoint(x: 24, y: WorkspaceTabStrip.height / 2)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let clickedAt = Date()
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseUp))
        let deadline = Date().addingTimeInterval(2)
        while selectedAt == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        let delay = try XCTUnwrap(selectedAt, "the click never selected the tab").timeIntervalSince(clickedAt)
        print("tab chip click → select", Int(delay * 1000), "ms (double-click interval", Int(NSEvent.doubleClickInterval * 1000), "ms)")
        XCTAssertLessThan(delay, 0.1, "a single click waited for a possible double click")
        window.close()
    }
}
