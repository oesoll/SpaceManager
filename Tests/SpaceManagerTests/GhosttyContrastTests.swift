import AppKit
import GhosttyKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// Claude mod(tool-lines)가 끝난 도구 호출 줄을 칠하는 회색 #767676이 그대로 회색으로 그려지는가.
/// Ghostty의 minimum-contrast는 대비가 모자라면 글자를 순백/순흑으로 바꿔 버린다(shaders.metal의
/// contrasted_color) — xterm.js는 모자란 만큼만 밝혔다. SEOL 10/31: "fine에선 도구호출이 회색으로 잘 안
/// 보이는데 지금은 너무 잘 보여서 눈이 아파". 결과는 `.build/window-capture/contrast-*.png`.
@MainActor
final class GhosttyContrastTests: XCTestCase {
    func testModGreyStaysGrey() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let size = NSSize(width: 600, height: 60)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        window.orderFrontRegardless()
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("contrast-\(UUID().uuidString).sh")
        // tool-lines의 끝난 줄: 흐린 회색 #767676(118,118,118)으로 "run | ls".
        try "printf '\\033[?25l\\033[38;2;118;118;118mrun | ls -la something long enough\\033[0m\\n'; sleep 60\n"
            .write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let term = GhosttyTerminalView(launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
                                       theme: TerminalPalette.workspaceDark.ghosttyTheme)
        term.frame = NSRect(origin: .zero, size: size)
        window.contentView = term
        defer { term.terminate(); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        var shipped: Int?
        for (name, extra) in [("shipped", [String]()), ("contrast-1", ["minimum-contrast = 1"]), ("contrast-4.5", ["minimum-contrast = 4.5"])] {
            let text = GhosttyConfigText.make(theme: TerminalPalette.workspaceDark.ghosttyTheme) + "\n" + extra.joined(separator: "\n") + "\n"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("contrast-\(UUID().uuidString).conf")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let config = try XCTUnwrap(ghostty_config_new())
            ghostty_config_load_file(config, file.path)
            ghostty_config_finalize(config)
            try? FileManager.default.removeItem(at: file)
            ghostty_surface_update_config(try XCTUnwrap(term.surface), config)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let image = try XCTUnwrap(Self.capture(window))
            let brightest = Self.brightestGreen(image)
            print("contrast", name, "brightest text green", brightest, String(format: "(#%02x%02x%02x)", brightest, brightest, brightest))
            if name == "shipped" { shipped = brightest }
            let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/window-capture")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("contrast-\(name).png"))
        }
        // 회색은 회색이어야 한다: 본문색(#d0d0d2, 208)보다 확연히 어둡게. 순백(255)이면 mod의 뜻이 뒤집힌 것이다.
        XCTAssertLessThan(try XCTUnwrap(shipped), 170, "the mod's faded grey is drawn brighter than body text")
    }

    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue()
    }

    /// 글자 획 한가운데(가장 밝은 화소)의 녹색 값. 회색이라 세 채널이 같다.
    private static func brightestGreen(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var best = 0
        for index in stride(from: 1, to: pixels.count, by: 4) { best = max(best, Int(pixels[index])) }
        return best
    }
}
