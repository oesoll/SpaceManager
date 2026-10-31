import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

final class TerminalHostTests: XCTestCase {
    private func makeHost(preparePresentation: @escaping (GhosttyTerminalView, @escaping () -> Void) -> Void = { view, completion in
        view.prepareForPresentation(completion)
    }) -> (NSWindow, TerminalHostView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = TerminalHostView(frame: window.contentView!.bounds, preparePresentation: preparePresentation)
        host.animatesTransitions = false
        window.contentView = host
        return (window, host)
    }

    private func settle(_ interval: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { settle(0.02) }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    func testSwapKeepsOutgoingSurfaceUntilNewSurfacePaintsThenReusesCachedViews() {
        // Control the asynchronous paint acknowledgement independently of the
        // WindowServer (which pauses rendering in background test runners).
        var painted: [() -> Void] = []
        let (window, host) = makeHost { _, completion in painted.append(completion) }
        defer { window.contentView = nil }
        let first = GhosttyTerminalView(frame: .zero)
        let second = GhosttyTerminalView(frame: .zero)

        XCTAssertTrue(host.show(first))
        XCTAssertTrue(first.superview === host)
        XCTAssertEqual(first.frame, host.bounds)
        XCTAssertFalse(host.show(first))

        XCTAssertTrue(host.show(second))
        XCTAssertTrue(first.superview === host, "Keep the old surface while the cold page loads")
        XCTAssertEqual(first.alphaValue, 1)
        XCTAssertTrue(host.subviews.last === first, "The old surface covers the new one until it has drawn")
        XCTAssertEqual(second.frame, host.bounds)
        painted.last?()
        waitUntil("The new surface's first frame releases the outgoing surface") { first.superview == nil }
        XCTAssertTrue(host.subviews.first === second)
        XCTAssertEqual(host.subviews.count, 1)

        let inactiveFrame = first.frame
        host.setFrameSize(NSSize(width: 800, height: 500))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.frame, inactiveFrame, "Hidden terminals must not be resized")
        XCTAssertEqual(second.frame, host.bounds)

        XCTAssertTrue(host.show(first))
        XCTAssertEqual(first.frame, host.bounds)
        painted.last?()
        waitUntil("Cached tabs also repaint before the old surface is removed") { second.superview == nil }
        XCTAssertTrue(host.subviews.first === first)
        XCTAssertFalse(host.constraints.contains {
            ($0.firstItem as? NSView) === second || ($0.secondItem as? NSView) === second
        }, "No constraint may retain the detached terminal")
    }

    func testRapidTabSwitchesKeepAtMostTwoSurfacesAndIgnoreStalePaints() {
        var painted: [() -> Void] = []
        let (window, host) = makeHost { _, completion in painted.append(completion) }
        defer { window.contentView = nil }
        let first = GhosttyTerminalView(frame: .zero)
        let second = GhosttyTerminalView(frame: .zero)
        let third = GhosttyTerminalView(frame: .zero)
        host.show(first)
        host.show(second)
        host.show(third)
        XCTAssertEqual(host.subviews.count, 2)
        XCTAssertTrue(host.subviews.last === first)
        XCTAssertNil(second.superview)
        host.show(first)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(host.subviews.first === first)
        XCTAssertEqual(first.alphaValue, 1)
        painted.forEach { $0() }
        settle(0.3)
        XCTAssertTrue(host.terminal === first)
        XCTAssertTrue(first.superview === host, "Stale callbacks cannot remove the current tab")
    }

    func testInterruptedPanelAnimationAndLiveResizeReleaseOnlyTheLatestSize() {
        let (window, host) = makeHost()
        defer { window.contentView = nil }
        let terminal = GhosttyTerminalView(frame: .zero)
        host.show(terminal)
        let transition = TerminalLayoutTransition()
        transition.attach(host)
        let initial = terminal.frame
        let first = transition.begin()
        host.setFrameSize(NSSize(width: 720, height: 480))
        host.layoutSubtreeIfNeeded()
        let second = transition.begin()
        transition.finish(first)
        settle()
        XCTAssertEqual(terminal.frame, initial)
        host.setFrameSize(NSSize(width: 900, height: 480))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame, initial)
        transition.finish(second)
        settle()
        XCTAssertEqual(terminal.frame, host.bounds)

        let beforeDrag = terminal.frame
        host.viewWillStartLiveResize()
        host.setFrameSize(NSSize(width: 1000, height: 600))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame, beforeDrag)
        host.viewDidEndLiveResize()
        settle()
        XCTAssertEqual(terminal.frame, host.bounds)
    }

    func testTabSelectedDuringPanelAnimationKeepsTheHeldViewport() {
        let (window, host) = makeHost()
        defer { window.contentView = nil }
        let first = GhosttyTerminalView(frame: .zero)
        let second = GhosttyTerminalView(frame: .zero)
        host.show(first)
        let initial = first.frame
        host.setResizeDeferred(true)
        host.setFrameSize(NSSize(width: 824, height: 480))
        host.layoutSubtreeIfNeeded()
        host.show(second)
        XCTAssertEqual(second.frame, initial)
        host.setResizeDeferred(false)
        // 놓은 뒤 크기가 한 프레임 동안 그대로인 것을 보고서야 준다(스프링 꼬리의 1px 움직임마다 주지 않게).
        XCTAssertEqual(second.frame, initial, "released before the host stopped moving")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(second.frame, host.bounds)
        XCTAssertEqual(first.frame, initial)
    }

    func testDetachedHostCannotStealAnOnscreenTerminal() {
        let (window, visibleHost) = makeHost()
        defer { window.contentView = nil }
        let terminal = GhosttyTerminalView(frame: .zero)
        visibleHost.show(terminal)
        let detachedHost = TerminalHostView(frame: .zero)
        detachedHost.show(terminal)
        detachedHost.layoutSubtreeIfNeeded()
        XCTAssertTrue(terminal.superview === visibleHost)
        XCTAssertTrue(detachedHost.subviews.isEmpty)
        XCTAssertEqual(terminal.frame, visibleHost.bounds)
    }

    func testInputTargetsTheSelectedTabWhileTheOutgoingSurfaceCoversIt() {
        let (window, host) = makeHost { _, _ in } // Hold the incoming paint acknowledgement.
        defer { window.contentView = nil }
        let first = GhosttyTerminalView(frame: .zero)
        let second = GhosttyTerminalView(frame: .zero)
        host.show(first)
        host.show(second)
        XCTAssertTrue(host.subviews.last === first)
        let point = host.convert(NSPoint(x: 100, y: 100), to: host.superview)
        let target = host.hitTest(point)
        XCTAssertTrue(target === second || target?.isDescendant(of: second) == true)
        second.focusTerminal()
        let responder = window.firstResponder as? NSView
        XCTAssertTrue(responder?.isDescendant(of: second) == true)
        XCTAssertFalse(responder?.isDescendant(of: first) == true)
    }
}
