import AppKit

/// 메뉴 막대의 sm 아이콘. 누르면 sm을 숨기고, 다시 누르면 보인다(SEOL 11/01). 오른쪽 클릭(⌃클릭)이면 메뉴.
///
/// agentOS 메뉴 막대(같은 SEOL의 앱)를 따랐다: "보이는 중"은 창이 떠 있는 것이 아니라 sm이 앞에 있고 그 창이
/// 키 창인 것이다 — 다른 앱 뒤에 깔린 sm은 한 번 누르면 앞으로 나온다. 숨기기는 macOS의 앱 숨기기(⌘H)라
/// 즉시 사라지고 포커스가 직전 앱으로 돌아가며, 다시 보이면 창이 겹친 순서 그대로 돌아온다. 화면 노치는
/// sm의 창이지만 숨기지 않는다(노치 패널은 `canHide = false`).
@MainActor
final class StatusBarToggle: NSObject {
    static let shared = StatusBarToggle()

    private var item: NSStatusItem?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.glyph()
            button.toolTip = "sm — 누르면 숨기기 · 보이기"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("sm")
        }
        self.item = item
    }

    enum Action: Equatable { case hide, show }

    /// 눌렀을 때 할 일. sm이 앞에 있고 키 창이 sm 작업 창이면 숨기고, 아니면(숨겨졌거나 뒤에 깔렸거나 창이
    /// 없거나) 보인다.
    static func action(isHidden: Bool, isActive: Bool, keyIsWorkWindow: Bool) -> Action {
        !isHidden && isActive && keyIsWorkWindow ? .hide : .show
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        let key = NSApp.keyWindow
        let keyIsWork = key.map { $0.isVisible && Self.isWorkWindow($0) } ?? false
        switch Self.action(isHidden: NSApp.isHidden, isActive: NSApp.isActive, keyIsWorkWindow: keyIsWork) {
        case .hide: NSApp.hide(nil)
        case .show: show()
        }
    }

    func show() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.orderedWindows.filter(Self.isWorkWindow)
        // 최소화했거나 닫아 둔 창만 있으면 앞으로 꺼낸다. 이미 떠 있으면 활성화만으로 겹친 순서 그대로 나온다.
        if !windows.contains(where: \.isVisible) {
            for window in windows.reversed() {
                if window.isMiniaturized { window.deminiaturize(nil) } else { window.orderFront(nil) }
            }
        }
        (windows.first { $0.isVisible } ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        let showing = Self.action(isHidden: NSApp.isHidden, isActive: NSApp.isActive,
                                  keyIsWorkWindow: NSApp.keyWindow.map(Self.isWorkWindow) ?? false) == .hide
        menu.addItem(withTitle: showing ? "sm 숨기기" : "sm 보이기", action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "sm 끝내기", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil   // 왼쪽 클릭은 다시 숨기기·보이기로.
    }

    @objc private func menuToggle() { toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// sm 작업 창(노치·알림 같은 패널은 뺀다).
    private static func isWorkWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain
    }

    /// 단색(template) 그림: sm의 모양 그대로 — 좁은 사이드바 카드와 넓은 터미널 카드. 앱 아이콘은 그림 전체가
    /// 그라데이션이라 메뉴 막대 크기에선 색 덩어리로만 보여서, 메뉴 막대의 다른 아이콘처럼 단색으로 그린다.
    static func glyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 4.5, height: 12), xRadius: 1.6, yRadius: 1.6).fill()
            NSBezierPath(roundedRect: NSRect(x: 7.5, y: 3, width: 9, height: 12), xRadius: 1.6, yRadius: 1.6).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "sm"
        return image
    }
}
