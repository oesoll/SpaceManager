import AppKit

/// 메뉴 막대의 sm 아이콘. 한 번 누르면 sm 창을 전부 숨기고, 다시 누르면 숨겼던 창을 그 순서 그대로 되돌린다
/// (SEOL 11/01: "한번 누르면 전체 숨기기 다시 누르면 보이기").
///
/// 앱 숨기기(⌘H, `NSApp.hide`)는 쓰지 않는다 — 화면 노치도 sm의 창이라 같이 사라진다. 작업 창만 내리고 올린다.
/// 보이는 창이 하나도 없을 때 누르면(전부 최소화했거나 닫았다) 숨길 것이 없으니 창을 앞으로 가져온다.
@MainActor
final class StatusBarToggle: NSObject {
    static let shared = StatusBarToggle()

    private var item: NSStatusItem?
    /// 숨긴 창들, 앞에 있던 것부터.
    private(set) var hidden: [NSWindow] = []

    var isHiding: Bool { !hidden.isEmpty }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.icon()
            button.toolTip = "sm 창 숨기기 · 보이기"
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityLabel("sm 창 숨기기 또는 보이기")
        }
        self.item = item
    }

    @objc func toggle() {
        if isHiding {
            reveal()
        } else if !Self.workWindows().isEmpty {
            hideAll()
        } else {
            showAll()
        }
    }

    func hideAll() {
        hidden = Self.workWindows()
        hidden.forEach { $0.orderOut(nil) }
    }

    func reveal() {
        let windows = hidden
        hidden = []
        NSApp.activate(ignoringOtherApps: true)
        // 뒤에 있던 창부터 올려 마지막에 맨 앞 창이 키를 받는다 — 숨기기 전 겹친 순서가 그대로다.
        for window in windows.reversed() { window.orderFront(nil) }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func showAll() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) && window.canBecomeMain {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
    }

    /// 보이는 sm 작업 창(노치·알림 같은 패널은 뺀다), 앞에 있는 것부터.
    private static func workWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// 앱 아이콘을 메뉴 막대 크기로.
    private static func icon() -> NSImage {
        let source = NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}
