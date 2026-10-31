import AppKit
import GhosttyKit
import WebKit
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

/// 같은 글자·같은 색을 웹뷰(xterm.js 시절, 지금 Fine)와 libghostty로 나란히 그려 획의 굵기를 잰다.
/// SEOL 10/31 "앱 글꼴이 너무 얇아, Fine에서 쓰는 걸로". 두 쪽 다 Menlo 13이라(웹뷰가 실제로 고른 글꼴을
/// 캔버스 서명으로 확인) 다른 것은 그리는 방식이다 — macOS가 웹뷰 글자는 획을 다듬어 두껍게 그린다.
/// 잉크 = 바탕보다 밝은 만큼의 합. 결과는 `.build/window-capture/weight.json`과 `weight-*.png`.
@MainActor
final class GhosttyWeightTests: XCTestCase {
    static let text = "Running tests... (38s - esc to interrupt) Update(src/components/PriceRow.tsx) {gjy}[]|@#"

    func testInkAgainstWebKit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let half = NSSize(width: 760, height: 60)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: half.width * 2, height: half.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: half.width * 2, height: half.height)))
        window.contentView = root
        window.orderFrontRegardless()

        let web = WKWebView(frame: NSRect(origin: .zero, size: half))
        root.addSubview(web)
        web.loadHTMLString("""
        <html><body style="margin:0;background:#1e1e1e"><div style="font:13px Menlo;color:#d0d0d2;white-space:pre;padding:4px 0 0 0">\(Self.text)</div></body></html>
        """, baseURL: nil)

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("weight-\(UUID().uuidString).sh")
        try "printf '%s\\n' '\(Self.text)'; sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let term = GhosttyTerminalView(launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
                                       theme: TerminalPalette.workspaceDark.ghosttyTheme)
        term.frame = NSRect(origin: NSPoint(x: half.width, y: 0), size: half)
        root.addSubview(term)
        defer { term.terminate(); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))

        var rows: [[String: Any]] = []
        // 웹뷰는 첫 장면만 잰다 — 이 창에서 표면 설정을 바꾸면 그 뒤로 웹뷰가 찍히지 않는다.
        var webInk = 0.0
        let variants: [(String, [String])] = [
            ("current", []),
            ("off", ["font-thicken = false"]),
            ("thicken-0", ["font-thicken = true", "font-thicken-strength = 0"]),
            ("thicken-64", ["font-thicken = true", "font-thicken-strength = 64"]),
            ("thicken-128", ["font-thicken = true", "font-thicken-strength = 128"]),
            ("thicken-192", ["font-thicken = true", "font-thicken-strength = 192"]),
            ("thicken-255", ["font-thicken = true", "font-thicken-strength = 255"]),
        ]
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/window-capture")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, extra) in variants {
            let config = try XCTUnwrap(Self.config(extra: extra))
            ghostty_surface_update_config(try XCTUnwrap(term.surface), config)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let image = try XCTUnwrap(Self.capture(window))
            if webInk == 0 { webInk = Self.ink(image, left: true) }
            let ghosttyInk = Self.ink(image, left: false)
            let ratio = (ghosttyInk / webInk * 1000).rounded() / 1000
            print("weight", name, "webkit", Int(webInk), "ghostty", Int(ghosttyInk), "ratio", ratio)
            rows.append(["variant": name, "webkit": webInk, "ghostty": ghosttyInk, "ratio": ratio])
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("weight-\(name).png"))
        }
        // 지금 설정(GhosttyConfigText)이 웹뷰와 같은 굵기여야 한다 — SEOL이 비교하는 Fine(웹뷰) 쪽이다.
        let current = try XCTUnwrap(rows.first { $0["variant"] as? String == "current" }?["ratio"] as? Double)
        XCTAssertEqual(current, 1, accuracy: 0.05, "terminal strokes are lighter or heavier than WebKit's")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: out.appendingPathComponent("weight.json"))
    }

    private static func config(extra: [String]) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("weight-\(UUID().uuidString).conf")
        let text = GhosttyConfigText.make(theme: TerminalPalette.workspaceDark.ghosttyTheme) + "\n" + extra.joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        try? FileManager.default.removeItem(at: file)
        return config
    }

    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue()
    }

    /// 바탕(#1e1e1e)보다 밝은 만큼의 합(녹색 채널). 왼쪽 반 = 웹뷰, 오른쪽 반 = Ghostty.
    private static func ink(_ image: CGImage, left: Bool) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let from = left ? 0 : width / 2, to = left ? width / 2 : width
        var sum = 0.0
        for y in 0..<height {
            for x in from..<to {
                let green = Double(pixels[(y * width + x) * 4 + 1])
                sum += max(0, green - 0x1e)
            }
        }
        return sum
    }
}
