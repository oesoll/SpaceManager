import Foundation
import Combine

/// 탭 하나의 패널들. 탭 자신(앵커 세션)이 첫 패널이고, 나눌 때마다 같은 작업 폴더·실행 위치의
/// 터미널이 하나씩 붙는다. tmux 창 안의 분할을 sm이 대신 갖는 자리다.
///
/// 한계: 앵커 패널은 따로 닫지 않는다(탭을 닫으면 함께 닫힌다). 나눈 패널은 앱을 다시 띄우면
/// 복원되지 않는다 — 셸 탭과 같은 규칙이다. 에이전트 패널을 재개해야 할 때 배치와 함께 저장한다.
final class PaneGroup: ObservableObject, Identifiable {
    let anchor: TerminalSession
    @Published private(set) var layout: PaneLayout
    @Published private(set) var focused: UUID
    @Published private(set) var extras: [UUID: TerminalSession] = [:]
    /// 포커스된 패널 하나만 탭 전체로 키워 본다(tmux·herdr의 zoom). 다른 패널은 그대로 돈다.
    @Published private(set) var isZoomed = false
    private var exitWatchers: [UUID: AnyCancellable] = [:]

    var id: UUID { anchor.id }

    init(anchor: TerminalSession) {
        self.anchor = anchor
        self.layout = .pane(anchor.id)
        self.focused = anchor.id
    }

    var paneIDs: [UUID] { layout.paneIDs }
    var isSplit: Bool { layout.paneCount > 1 }

    func session(for id: UUID) -> TerminalSession? {
        id == anchor.id ? anchor : extras[id]
    }

    var focusedSession: TerminalSession { session(for: focused) ?? anchor }

    /// 포커스된 패널을 나눠 새 터미널을 오른쪽(가로) 또는 아래(세로)에 연다.
    @discardableResult
    func split(_ axis: PaneAxis, make: (UUID) -> TerminalSession) -> TerminalSession {
        let id = UUID()
        let session = make(id)
        extras[id] = session
        layout = layout.splitting(focused, axis: axis, newPane: id)
        isZoomed = false
        watchExit(of: session)
        focus(id)
        return session
    }

    func focus(_ id: UUID) {
        guard layout.contains(id) else { return }
        if focused != id { focused = id }
        session(for: id)?.focusTerminal()
    }

    func focus(toward direction: PaneDirection) {
        guard let next = layout.neighbor(of: focused, toward: direction) else { return }
        focus(next)
    }

    /// 화면 순서로 다음(또는 이전) 패널. 끝에서 처음으로 돈다.
    func cycleFocus(forward: Bool) {
        let ids = paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focused) else { return }
        focus(ids[(index + (forward ? 1 : ids.count - 1)) % ids.count])
    }

    func toggleZoom() {
        isZoomed = isSplit && !isZoomed
    }

    func setRatio(_ ratio: Double, at path: [Bool]) {
        let next = layout.settingRatio(ratio, at: path)
        if next != layout { layout = next }
    }

    /// 나눈 패널을 닫는다. 그 터미널의 프로세스도 끝난다. 앵커는 닫지 않는다.
    func close(_ id: UUID) {
        guard id != anchor.id, let session = extras[id], let next = layout.removing(id) else { return }
        exitWatchers[id] = nil
        extras[id] = nil
        session.cleanup()
        layout = next
        if !isSplit { isZoomed = false }
        if focused == id { focus(next.paneIDs.first ?? anchor.id) }
    }

    /// 탭이 닫힐 때 나눈 패널들을 함께 정리한다.
    func closeAll() {
        for id in Array(extras.keys) { close(id) }
    }

    /// 셸에서 `exit`하면 그 패널이 닫힌다(tmux와 같다). 재연결 중인 원격 패널은 끝난 게 아니다.
    private func watchExit(of session: TerminalSession) {
        exitWatchers[session.id] = session.$isRunning
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session, !session.isReconnecting, session.startError == nil else { return }
                self.close(session.id)
            }
    }
}

/// 창 하나가 가진 탭별 패널 묶음. 탭을 처음 나누는 순간 생긴다 — 나누지 않은 탭은 지금과 똑같이 그린다.
final class PaneStore: ObservableObject {
    @Published private(set) var groups: [UUID: PaneGroup] = [:]

    func group(for tab: TerminalSession) -> PaneGroup? { groups[tab.id] }

    func ensureGroup(for tab: TerminalSession) -> PaneGroup {
        if let existing = groups[tab.id] { return existing }
        let group = PaneGroup(anchor: tab)
        groups[tab.id] = group
        return group
    }

    func discard(tabID: UUID) {
        groups.removeValue(forKey: tabID)?.closeAll()
    }
}
