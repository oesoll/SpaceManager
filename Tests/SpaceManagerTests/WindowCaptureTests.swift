import AppKit
import SwiftUI
import XCTest
@testable import SpaceManager

/// 실제 창을 띄워 창 서버에서 합성된 그대로 찍는다 — 사이드바 유리와 터미널 색은
/// `cacheDisplay`로 잡히지 않는다. 실제 워크스페이스와 tmux를 건드리지 않도록
/// `SM_CAPTURE=1`일 때만, 그리고 격리된 홈(`scripts/test-isolated.sh`)과
/// 격리된 `TMUX_TMPDIR`에서만 돈다. 결과는 `.build/window-capture/`.
final class WindowCaptureTests: XCTestCase {
    @MainActor
    func testCaptureWorkspaceAndQuickWindows() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SM_CAPTURE"] == "1", "set SM_CAPTURE=1")
        let home = FileManager.default.homeDirectoryForCurrentUser
        // CFFIXED_USER_HOME은 Foundation의 홈만 바꾼다. 진짜 홈은 계정 DB에서 읽는다.
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        guard home.standardizedFileURL != realHome.standardizedFileURL,
              let tmuxDir = env["TMUX_TMPDIR"], !tmuxDir.hasPrefix("/tmp") else {
            throw XCTSkip("run through scripts/test-isolated.sh with an isolated TMUX_TMPDIR")
        }

        // 격리된 홈에 워크스페이스 셋을 심는다 — 첫 창이 레거시 목록을 이관해 첫 항목을 연다.
        let storage = home.appendingPathComponent(".space-manager")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var workspaces: [Workspace] = []
        for name in ["Fine", "trip-journal", "cometro"] {
            let dir = home.appendingPathComponent("work/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            workspaces.append(Workspace(rootPath: dir.path))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(workspaces).write(to: storage.appendingPathComponent("workspaces.json"))

        let tag = env["SM_CAPTURE_TAG"].map { "-\($0)" } ?? ""
        // 첫 창만 레거시 목록을 이관받는다. 한 프로세스에 한 장면씩 — SM_CAPTURE_CASE로 고른다.
        let cases = [("workspace-dark", "dark"), ("workspace-light", "light")]
        for (name, appearance) in cases where name == (env["SM_CAPTURE_CASE"] ?? "workspace-dark") {
            UserDefaults.standard.set(appearance, forKey: "preferredAppearance")
            let image = try capture(ContentView(), dark: appearance == "dark")
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/window-capture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("\(name)\(tag).png"))
        }
    }

    @MainActor
    private func capture(_ root: some View, dark: Bool) throws -> CGImage {
        let size = NSSize(width: 1240, height: 780)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))

        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        let createImage = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CGWindowListCreateImage")), to: CreateImage.self)
        return try XCTUnwrap(createImage(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue())
    }
}
