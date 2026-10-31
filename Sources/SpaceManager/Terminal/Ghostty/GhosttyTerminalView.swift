// Parts adapted from Ghostty (MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).
// See LICENSE-ghostty in this folder.
import AppKit
import Carbon
import GhosttyKit

/// 터미널 하나 = libghostty 표면 하나. 표면이 PTY와 자식 프로세스를 직접 쥐고 Metal로 그린다.
///
/// 키 입력은 Ghostty macOS 앱의 SurfaceView_AppKit.swift(MIT)를 옮겼다. 특히 한글 조합은
/// `interpretKeyEvents`와 NSTextInputClient를 거쳐야 하고, 수정자를 바꾸지 않은 키는 원래 NSEvent를
/// 그대로 넘겨야 조합이 깨지지 않는다(Ghostty가 실측으로 남긴 주의).
final class GhosttyTerminalView: NSView, NSTextInputClient {
    /// 표면을 띄울 명령. nil이면 로그인 셸.
    struct Launch: Equatable {
        var command: String?
        var workingDirectory: String
        var environment: [String: String] = [:]
    }

    private(set) var surface: ghostty_surface_t?
    let launch: Launch

    /// 자식 프로세스가 끝났다(종료 코드). 재연결할지는 세션이 정한다.
    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?

    private var markedText = NSMutableAttributedString()
    /// keyDown 안에서만 non-nil. 그동안 IME가 확정한 글자를 모았다가 키 이벤트로 보낸다.
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var cellSize = NSSize(width: 8, height: 16)
    private var contentSize = NSSize.zero
    private var trackingArea: NSTrackingArea?
    private var pendingPresentation: (() -> Void)?
    private var exited = false

    /// 프로세스 없는 빈 표면. 호스트 뷰의 갈아 끼우기만 시험할 때 쓴다.
    override convenience init(frame: NSRect) {
        self.init(launch: nil, palette: .workspaceDark)
        self.frame = frame
    }

    init(launch: Launch?, palette: TerminalPalette) {
        self.launch = launch ?? Launch(command: nil, workingDirectory: NSHomeDirectory())
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let launch, let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0
        // 끝나도 표면을 닫지 않는다 — 끊기기 전 마지막 화면을 남겨 둔 채 세션이 재연결을 정한다.
        config.wait_after_command = true
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = launch.environment.keys.sorted()
        let cKeys = keys.map { strdup($0) }
        let cValues = keys.map { strdup(launch.environment[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var env = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }

        surface = launch.workingDirectory.withCString { cwd in
            config.working_directory = cwd
            return env.withUnsafeMutableBufferPointer { buffer in
                config.env_vars = buffer.baseAddress
                config.env_var_count = buffer.count
                if let command = launch.command {
                    return command.withCString { cmd in
                        config.command = cmd
                        return ghostty_surface_new(app, &config)
                    }
                }
                return ghostty_surface_new(app, &config)
            }
        }
        if let surface, let palette = GhosttyRuntime.shared.config(for: palette) {
            ghostty_surface_update_config(surface, palette)
        }
        // 표면은 포커스된 채로 태어난다. 알려 주지 않으면 포커스 없는 패널마다 깜박이는 커서를 그린다(SEOL 10/31).
        if let surface { ghostty_surface_set_focus(surface, false) }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - sm 쪽 연결

    func setPalette(_ palette: TerminalPalette) {
        guard let surface, let config = GhosttyRuntime.shared.config(for: palette) else { return }
        ghostty_surface_update_config(surface, config)
    }

    func focusTerminal() {
        window?.makeFirstResponder(self)
    }

    /// 지금 터미널 앞에서 도는 프로세스(Quick의 대화 id 찾기에 쓴다).
    var foregroundProcessIdentifier: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    var isProcessRunning: Bool { surface != nil && !exited }

    /// 글자를 붙여 넣는다(테스트와 CLI용). 붙여넣기라 셸이 바로 실행하지 않는다 — 실행은 `pressReturn`.
    func sendText(_ text: String) {
        guard let surface, !exited else { return }
        let length = text.utf8CString.count - 1
        text.withCString { ghostty_surface_text(surface, $0, UInt(length)) }
    }

    /// 리턴 키를 누른다.
    func pressReturn() {
        guard let surface, !exited else { return }
        var key = ghostty_input_key_s()
        key.keycode = 36 // kVK_Return
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 13
        key.action = GHOSTTY_ACTION_PRESS
        _ = "\r".withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    /// 표면을 닫는다. 자식 프로세스는 PTY가 닫히며 SIGHUP을 받는다.
    func terminate() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    func childDidExit(code: Int32) {
        guard !exited else { return }
        exited = true
        onExit?(code)
    }

    func surfaceDidClose() {
        // wait_after_command라 프로세스 종료로는 오지 않는다. 사용자가 끝난 표면에서 키를 눌렀을 때 온다.
        childDidExit(code: 0)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
    }

    func cellSizeDidChange(width: Double, height: Double) {
        guard let window else { return }
        let scale = window.backingScaleFactor
        cellSize = NSSize(width: width / scale, height: height / scale)
    }

    func didRender() {
        let done = pendingPresentation
        pendingPresentation = nil
        done?()
    }

    /// 탭을 바꿀 때 새 표면이 한 장을 그릴 때까지 옛 표면을 덮어 둔다. Metal은 붙자마자 그리므로
    /// 다음 런루프 두 번이면 충분하다(렌더 알림은 단일 스레드 런타임에서만 온다).
    func prepareForPresentation(_ completion: @escaping () -> Void) {
        pendingPresentation = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.didRender() }
    }

    func cancelPresentation() {
        pendingPresentation = nil
    }

    // MARK: - 크기와 배율

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, contentSize.width > 0, contentSize.height > 0 else { return }
        let backing = convertToBacking(contentSize)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in self?.syncFocus()
                })
            }
        }
        guard let surface else { return }
        // 창에서 떨어진 표면은 그리지 않는다 — 보이지 않는 탭이 GPU를 쓰지 않게.
        ghostty_surface_set_occlusion(surface, window != nil)
        if window != nil { viewDidChangeBackingProperties() }
        syncFocus()
    }

    private var keyObservers: [NSObjectProtocol] = []

    /// 포커스는 "이 창이 앞에 있고, 이 터미널이 키를 받는다"일 때만. 아니면 커서를 그리지 않는다.
    private func syncFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.isKeyWindow == true && window?.firstResponder === self)
    }

    // MARK: - 포커스

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow ?? true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    private var isFocused: Bool { window?.firstResponder === self }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isFocused { window?.makeFirstResponder(self) }
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event)
    }

    private func sendButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        // 음수는 커서가 표면 밖이라는 뜻이다.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Ghostty와 같은 배율 — 트랙패드는 두 배로 해야 손가락을 따라온다.
            x *= 2
            y *= 2
        }
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    // MARK: - 키보드

    override func keyDown(with event: NSEvent) {
        // 끝난 표면은 키를 받지 않는다 — libghostty는 끝난 표면에서 아무 키나 누르면 닫는다.
        // 재연결하는 동안에도 마지막 화면이 그대로 남아야 한다.
        if exited { return }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // option-as-alt 같은 설정에 따라 글자 해석에 쓸 수정자를 받는다.
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // 수정자가 같으면 원래 이벤트를 그대로 써야 한다 — 새로 만들면 한글 조합이 깨진다.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore: String? = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // 입력기가 키를 가져가 자판을 바꿨으면 터미널로 보내지 않는다.
        if !markedTextBefore && layoutBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        // 조합 중이던 글자가 이 키로 확정됐으면 확정된 글자를 따로 보내고, 그 뒤에도 터미널에
        // 닿아야 하는 키(방향키)만 다시 보낸다.
        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = committedText(action, text: text)
            }
            if Self.shouldReplayAfterCommit(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, composing: false)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// ⌘ 조합은 먼저 메뉴(sm 단축키)로 보낸다. 터미널 바인딩(복사·붙여넣기·전체 선택)과
    /// AppKit이 엉뚱하게 가로채는 ^⏎·^/만 여기서 처리한다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocused, let surface else { return false }

        var key = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            key.text = ptr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ^/는 맥이 삑 소리를 내므로 ^_로 보낸다.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            // 메뉴가 처리하지 않고 다시 돌아온 ⌃ 조합(같은 타임스탬프)만 터미널로 보낸다.
            if let last = lastPerformKeyEvent, last == event.timestamp, !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    override func doCommand(by selector: Selector) {
        // 메뉴가 처리하지 않은 ⌃ 조합을 이벤트 큐로 되돌려 keyDown에서 인코딩되게 한다.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var key = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = 0
        key.composing = false
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            let length = text.utf8CString.count
            if length > 0 {
                text.withCString { ghostty_surface_preedit(surface, $0, UInt(length - 1)) }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // 키 이벤트 밖에서 온 조합(자판 전환 등)은 바로 반영한다.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// 조합 창(한글 후보 등)이 뜰 자리 — 커서 셀.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0
        var width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += Double(cellSize.width) * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, Double(cellSize.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }
        unmarkText()
        if var accumulator = keyTextAccumulator {
            accumulator.append(chars)
            keyTextAccumulator = accumulator
            return
        }
        // IME·받아쓰기가 확정한 글자는 붙여넣기가 아니라 친 글자로 보낸다.
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    // MARK: - 변환 도우미

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // ⌃·⌘은 글자를 만드는 데 쓰이지 않는다고 본다(Ghostty의 오래된 규칙).
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// 제어 문자는 Ghostty가 직접 인코딩하므로 ⌃ 없는 글자로, 기능키(PUA)는 보내지 않는다.
    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    /// 조합 중에 들어온 제어 문자 하나는 입력기 몫이다.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let first = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex else { return false }
        return first.value < 0x20
    }

    /// 조합이 확정된 뒤에도 터미널에 닿아야 하는 키. 맨 왼쪽 화살표는 한글 입력기가 이미 커서를 두므로 뺀다.
    static func shouldReplayAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 124, 126: return true // 아래, 오른쪽, 위
        case 123: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
