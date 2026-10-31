import AppKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 한글을 조합하다 확정할 때(스페이스, 다음 음절) 그 글자가 잠깐 사라지는가. SEOL 10/31: "sm이든 fine이든
/// 띄어쓰기시 이전에 입력하던 한글이 깜빡이는 문제". 확정 순간 조합 표시를 지우는데, 확정된 글자는 PTY로 가서
/// 에이전트가 다시 그려야 보인다. 그 사이를 흉내 내려고 터미널 안에서는 받은 글자를 40ms 뒤에 돌려주는
/// 프로그램이 돈다(Claude가 입력란을 다시 그리는 지연). 그 칸을 4ms마다 찍어 비어 있던 시간을 잰다.
@MainActor
final class PreeditCommitTests: XCTestCase {
    func testCommittedSyllableNeverDisappears() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let size = NSSize(width: 400, height: 80)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("slow-echo-\(UUID().uuidString).sh")
        try """
        printf '\\033[?25lREADY\\n'
        stty -icanon -echo
        exec python3 -u -c 'import os,time
        while True:
            b = os.read(0, 64)
            if not b: break
            time.sleep(0.04)
            os.write(1, b)'
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        var blankRuns: [Double] = []
        defer { window.close() }
        for _ in 0..<5 {
            // 회차마다 새 터미널 — 앞 회차의 글자가 그 칸에 남지 않게.
            let term = GhosttyTerminalView(launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
                                           theme: TerminalPalette.workspaceDark.ghosttyTheme)
            term.frame = NSRect(origin: .zero, size: size)
            window.contentView = term
            window.orderFrontRegardless()
            window.makeKey()
            window.makeFirstResponder(term)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))

            // 둘째 줄 첫 두 칸(조합 중인 "한"이 그려지고, 확정 뒤 에코가 그려질 자리).
            let cell = term.cellSize
            let height = window.contentView?.bounds.height ?? size.height
            let rect = WindowProbe.screenRect(CGRect(x: 0, y: cell.height, width: cell.width * 2, height: cell.height), in: window)
            _ = height
            term.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            // 조합 글자가 실제로 그려질 때까지(에코 프로그램이 처음 뜨는 데 시간이 걸린다).
            var shown = 0.0
            let ready = Date().addingTimeInterval(3)
            while shown == 0 && Date() < ready {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                shown = try XCTUnwrap(Self.ink(window.windowNumber, rect))
            }
            XCTAssertGreaterThan(shown, 0, "the composing syllable was not drawn")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            // 스페이스로 확정.
            var shots: [[String: Any]]?
            let burstStart = CACurrentMediaTime()
            WindowProbe.burst(windowNumber: window.windowNumber, screenRect: rect, count: 80, every: 0.004, folder: nil,
                              start: burstStart) { shots = $0 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let committedAt = (CACurrentMediaTime() - burstStart) * 1000
            // 키 처리 안에서 입력기가 확정했을 때 앱이 타는 길.
            term.commitComposition(["한", " "], composing: "")
            let deadline = Date().addingTimeInterval(3)
            while shots == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            // 비어 있던 시간: 글자 칸의 잉크가 조합 때의 1/4 아래로 떨어진 장면들의 길이.
            let rows = try XCTUnwrap(shots)
            var blank = 0.0, last: Double?
            // 확정부터 150ms 안(에코 40ms가 오고 그려지기까지)만 본다.
            for row in rows where (row["t"] as? Double ?? 0) >= committedAt && (row["t"] as? Double ?? 0) <= committedAt + 150 {
                let t = row["t"] as? Double ?? 0
                let rgb = row["rgb"] as? [Double] ?? [0, 0, 0]
                let isBlank = (rgb[1] - 0x1e) * Double(rect.width * rect.height) < shown / 4
                if let previous = last, isBlank { blank += t - previous }
                last = isBlank ? t : nil
            }
            blankRuns.append((blank * 10).rounded() / 10)
            if blank > 0 {
                let times = rows.compactMap { row -> String? in
                    let rgb = row["rgb"] as? [Double] ?? [0, 0, 0]
                    return (rgb[1] - 0x1e) * Double(rect.width * rect.height) < shown / 4 ? String(format: "%.0f", row["t"] as? Double ?? 0) : nil
                }
                print("blank at ms:", times.prefix(20).joined(separator: ","))
            }
            term.terminate()
        }
        print("preedit commit blank ms per commit:", blankRuns)
        XCTAssertEqual(blankRuns.max() ?? 0, 0, accuracy: 10, "the committed syllable disappeared before its echo arrived")
    }

    /// 그 칸에서 바탕보다 밝은 만큼의 합(녹색).
    private static func ink(_ number: Int, _ rect: CGRect) -> Double? {
        guard let image = WindowProbe.image(windowNumber: number, screenRect: rect) else { return nil }
        let mean = WindowProbe.meanColor(image)
        return max(0, mean[1] - 0x1e) * Double(rect.width * rect.height)
    }
}
