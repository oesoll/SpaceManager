import AppKit
import XCTest
@testable import SpaceManager

/// libghostty 표면이 실제로 그리는지와 무게를 본다. `SM_CAPTURE=1`일 때만 돈다.
/// 결과는 `.build/window-capture/ghostty-<dark|light>.png`.
final class GhosttyCaptureTests: XCTestCase {
    @MainActor
    func testSurfaceDrawsKoreanAndColours() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let dark = (env["SM_CAPTURE_CASE"] ?? "dark") == "dark"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-sample-\(UUID().uuidString).sh")
        try """
        printf '\\033[1m⏺\\033[0m 리뷰를 마쳤습니다. 결제 금액 반올림이 두 군데에서 다릅니다.\\n'
        printf '  \\033[2m⎿  PriceRow는 Math.round, OrderSummary는 Math.floor\\033[0m\\n\\n'
        for i in 0 1 2 3 4 5 6 7; do printf "\\033[3${i}m■ 3$i \\033[9${i}m■ 9$i\\033[0m  "; done; printf '\\n\\n'
        printf '\\033[38;5;210m✻\\033[0m Running tests… \\033[2m(38s · esc to interrupt)\\033[0m\\n'
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 760, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        let rssBefore = Self.residentMB()
        let view = GhosttyTerminalView(
            launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
            palette: dark ? .workspaceDark : .workspaceLight)
        XCTAssertNotNil(view.surface, "ghostty_surface_new failed")
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        let rssOne = Self.residentMB()

        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        let createImage = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CGWindowListCreateImage")), to: CreateImage.self)
        let image = try XCTUnwrap(createImage(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("ghostty-\(dark ? "dark" : "light").png"))

        // 무게: 셸 표면 세 개를 더 연다. 웹뷰 때는 하나에 WebKit 프로세스 하나(수십 MB)였다.
        var more: [GhosttyTerminalView] = []
        for index in 0..<3 {
            let extra = GhosttyTerminalView(launch: .init(command: "/bin/sh -c 'sleep 30'", workingDirectory: "/"),
                                            palette: .workspaceDark)
            extra.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
            window.contentView?.addSubview(extra)
            more.append(extra)
            _ = index
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        let rssFour = Self.residentMB()
        let webkit = Self.webContentCount()
        print("GHOSTTYCOST rss before=\(rssBefore)MB one=\(rssOne)MB four=\(rssFour)MB webcontent=\(webkit)")
        for extra in more { extra.terminate() }
        view.terminate()
        window.orderOut(nil)
    }

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    private static func webContentCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pgrep -P \(getpid()) | wc -l"]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
