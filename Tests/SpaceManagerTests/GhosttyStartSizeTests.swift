import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 자식 프로세스가 태어나는 순간 보는 터미널 크기. libghostty는 표면을 800×600픽셀로 시작하므로, 크기를
/// 알기 전에 띄우면 `sm-session attach`가 그 작은 화면으로 에이전트를 줄였다가 다시 늘린다 — 처음 열 때
/// 잠깐 깨져 보이던 화면이다(SEOL 10/31). 창에 들어가 크기를 안 뒤 띄우면 처음부터 맞는 크기를 본다.
@MainActor
final class GhosttyStartSizeTests: XCTestCase {
    func testChildSeesThePaneSizeFromItsFirstMoment() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let deferred = try firstSize(startWhenSized: true)
        let immediate = try firstSize(startWhenSized: false)
        let settled = try finalSize()
        print("child's first size: deferred", deferred, "immediate", immediate, "pane", settled)
        XCTAssertEqual(deferred, settled, "the child started before the pane size was known")
    }

    private let paneSize = NSSize(width: 640, height: 320)

    /// 자식이 시작하자마자 읽은 "행 열".
    private func firstSize(startWhenSized: Bool) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("start-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = GhosttyTerminalView(
            launch: .init(command: "/bin/sh -c 'stty size > \(file.path); sleep 5'", workingDirectory: NSHomeDirectory()),
            theme: TerminalPalette.workspaceDark.ghosttyTheme, startWhenSized: startWhenSized)
        let window = host(view)
        defer { view.terminate(); window.close() }
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: file, encoding: .utf8))?.isEmpty != false && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 크기가 다 정해진 뒤 읽은 "행 열"(비교 기준).
    private func finalSize() throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("final-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = GhosttyTerminalView(
            launch: .init(command: "/bin/sh -c 'sleep 1; stty size > \(file.path); sleep 5'", workingDirectory: NSHomeDirectory()),
            theme: TerminalPalette.workspaceDark.ghosttyTheme, startWhenSized: false)
        let window = host(view)
        defer { view.terminate(); window.close() }
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: file, encoding: .utf8))?.isEmpty != false && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 패널처럼: 창에 붙이고 그다음 크기를 준다(SwiftUI 호스트가 하는 순서).
    private func host(_ view: GhosttyTerminalView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: paneSize.width, height: paneSize.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.accessory)
        window.orderFrontRegardless()
        let container = NSView(frame: NSRect(origin: .zero, size: paneSize))
        window.contentView = container
        view.frame = .zero
        container.addSubview(view)
        view.frame = NSRect(origin: .zero, size: paneSize)
        return window
    }
}
