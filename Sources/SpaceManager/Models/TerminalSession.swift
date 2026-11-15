import Foundation
import SwiftUI
import Combine
import GhosttyTerminal

/// 패널 하나의 터미널. libghostty 표면(PTY와 프로세스를 쥔다)을 소유해
/// SwiftUI 뷰 업데이트를 넘어 터미널을 살아있게 한다. 무엇에 붙는지(셸 / 세션 층의 세션)는 `attachment`가 말한다.
final class TerminalSession: Identifiable, ObservableObject, Equatable {
    let id: UUID
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var startError: String?
    /// 세션 패널의 attach가 끊겨 다시 붙는 중. 새 연결이 붙을 때까지 유지된다 —
    /// ssh 접속(프록시 경유 수 초) 동안에도 화면은 끊기기 전 그대로 두고 배지만 띄운다.
    @Published private(set) var isReconnecting = false
    var workingDirectory: String
    /// ssh 호스트 별칭. 셸 패널이면 그 기기의 셸이다(세션 패널은 세션 층이 기기를 고른다).
    let remoteHost: String?
    /// 셸 패널이 무엇에 붙는가(로그인 셸 또는 peer holder의 에이전트). 붙이는 방법은 TerminalAttachment에만 있다.
    let attachment: TerminalAttachment
    /// 배치 데이터의 패널이면 그 id(`p-…`)와 워크스페이스. 패널 안 셸이 `sm split`처럼 자기 자리를 알게
    /// `SM_PANE_ID`·`SM_WORKSPACE`로 넘긴다(세션 층 계약). 없으면 이 터미널의 id를 `SM_PANE_ID`로 쓴다.
    var layoutPane: (id: String, workspace: String)?

    /// 지금 화면에 붙은 터미널. libghostty 표면이 PTY와 자식 프로세스를 직접 쥔다.
    private(set) var terminalView: GhosttyTerminalView?
    /// 작업 창의 라이트/다크를 따른다. 터미널이 아직 없으면 만들 때 이 값을 쓴다.
    /// 화면이 다시 그려질 때마다 같은 값이 다시 들어온다 — 바뀐 때만 표면 설정을 다시 건다.
    var palette: TerminalPalette {
        didSet {
            guard palette != oldValue else { return }
            terminalView?.setTheme(palette.ghosttyTheme)
            if let stageDirectorStorage { MainActor.assumeIsolated { stageDirectorStorage.stage.theme = palette.ghosttyTheme } }
        }
    }

    // MARK: 세션 무대 (잠든 세션 화면)

    private var stageDirectorStorage: SessionStageDirector?
    /// 세션 층의 세션을 보이는 패널의 무대(마지막 화면·어두운 막·깨우기). 다른 패널은 nil — 예전처럼 표면 그대로.
    var stageDirector: SessionStageDirector? {
        if let stageDirectorStorage { return stageDirectorStorage }
        guard case .agent(let name, let host, _) = attachment else { return nil }
        return MainActor.assumeIsolated { () -> SessionStageDirector? in
            guard SessionStageDirector.enabled else { return nil }
            let director = SessionStageDirector(target: name + "@" + host) { [unowned self] in
                self.started = true
                return self.makeTerminal(noScreen: true)
            }
            director.stage.theme = palette.ghosttyTheme
            director.onLiveChange = { [weak self] view in
                guard let self else { return }
                self.objectWillChange.send()
                self.terminalView = view
                self.isRunning = view != nil
            }
            director.onReconnecting = { [weak self] value in
                guard let self, self.isReconnecting != value else { return }
                self.isReconnecting = value
            }
            stageDirectorStorage = director
            return director
        }
    }

    /// 무대가 이 패널을 맡고 있는가(보이기 시작한 뒤).
    private var stageIsActive: Bool {
        guard let stageDirectorStorage else { return false }
        return MainActor.assumeIsolated { stageDirectorStorage.isActive }
    }

    /// 내려 둔(무대가 쉬는) 세션 패널을 다시 붙인다. 보이는 패널에만 부른다.
    func resumeIfParked() {
        guard let stageDirectorStorage, !stageIsActive else { return }
        MainActor.assumeIsolated { stageDirectorStorage.begin() }
    }

    /// 세션 층에 보는 창으로 잡혀 있는가(attach 표면이 있거나, 무대가 상태를 듣고 있다).
    var holdsAttach: Bool { terminalView != nil || stageIsActive }

    /// 오래 가려진 패널의 attach를 내린다(LayoutTerminals.parkHidden). 무대가 맡은 패널은 마지막 화면을 장면으로
    /// 남겨 다시 보일 때 그 아래에서 다시 붙고, 아니면 터미널을 닫는다.
    func park() {
        if let stageDirectorStorage, stageIsActive {
            MainActor.assumeIsolated { stageDirectorStorage.park() }
        } else {
            cleanup()
        }
    }
    private var started = false
    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0
    /// 재연결 중 새로 띄운 표면. 붙었다고 볼 때까지 화면에는 끊기기 전 표면을 그대로 둔다.
    private var pendingView: GhosttyTerminalView?
    private var pendingTimer: Timer?

    init(id: UUID = UUID(), name: String, workingDirectory: String, remoteHost: String? = nil,
         attachment: TerminalAttachment = .shell) {
        self.attachment = attachment
        self.id = id
        self.palette = .workspaceDark
        self.name = name
        self.workingDirectory = workingDirectory
        self.remoteHost = remoteHost
        observeWake()
    }

    /// 화면에 붙일 터미널. 처음 부르는 순간 프로세스가 뜬다.
    func getOrCreateTerminal() -> GhosttyTerminalView {
        if let existing = terminalView { return existing }
        started = true
        let view = makeTerminal()
        terminalView = view
        return view
    }

    /// 이 탭의 명령으로 새 표면을 만든다(= 새 프로세스).
    /// `sizeHint`: 재연결할 때 끊긴 표면의 크기. 없으면(처음) 창에 들어가 크기를 안 뒤에 띄운다.
    private func makeTerminal(sizeHint: NSSize? = nil, noScreen: Bool = false) -> GhosttyTerminalView {
        cancelReconnectTimer()
        let startDir = FileManager.default.fileExists(atPath: workingDirectory)
            ? workingDirectory : NSHomeDirectory()
        let launch = Self.ghosttyLaunch(
            arguments: launchArguments(startDirectory: startDir, noScreen: noScreen),
            environment: launchEnvironment(),
            workingDirectory: startDir)
        let hint = sizeHint.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let view = GhosttyTerminalView(launch: launch, theme: palette.ghosttyTheme, startWhenSized: true, initialSize: hint)
        view.translatesAutoresizingMaskIntoConstraints = false
        let launchedAt = Date()
        view.onExit = { [weak self, weak view] code in
            guard let self, let view, self.started else { return }
            self.surfaceExited(view, code: code, connectedFor: Date().timeIntervalSince(launchedAt))
        }
        view.onNotification = { [weak self] title, body in self?.postTerminalNotice(title: title, body: body) }
        if view.failedToStart {
            startError = "터미널을 시작하지 못했습니다 (libghostty 표면 생성 실패)"
            isRunning = false
        } else {
            startError = nil
            isRunning = true
        }
        return view
    }

    private func launchArguments(startDirectory: String, noScreen: Bool = false) -> [String] {
        Self.launchArguments(attachment: attachment, remoteHost: remoteHost, workingDirectory: workingDirectory,
                             exitStatusPath: exitStatusPath, noScreen: noScreen)
    }

    /// 로그인 셸 인자: 세션 패널은 `sm-session attach`, 원격 셸 패널은 ssh 한 줄, 로컬 셸 패널은 그냥 로그인 셸.
    static func launchArguments(attachment: TerminalAttachment, remoteHost: String?, workingDirectory: String,
                                exitStatusPath: String? = nil, noScreen: Bool = false) -> [String] {
        if let command = attachment.command(recordingExitTo: exitStatusPath, noScreen: noScreen) {
            return ["-lc", command]
        }
        if let remoteHost, !remoteHost.trimmingCharacters(in: .whitespaces).isEmpty {
            // 원격 디렉토리는 원래 경로에서 계산한다 — 로컬에 없어도 원격엔 있다.
            return ["-lc", RemoteShell.shellCommand(host: remoteHost, directory: RemoteShell.directory(forLocalPath: workingDirectory))]
        }
        return []   // 순수 인터랙티브 로그인 셸
    }

    /// 앱 환경에서 바꿀 것만(더할 값, 지울 이름). TERM·COLORTERM은 Ghostty 설정이 준다.
    private func launchEnvironment() -> (set: [String: String], unset: [String]) {
        let base = ProcessInfo.processInfo.environment
        var env = base
        // 사용자 셸의 PATH — 앱이 Finder로 떠도 패널 안에서 ccv·sm-session 같은 사용자 명령을 찾는다.
        env["PATH"] = UserShellEnvironment.path
        // peer가 이 터미널의 에이전트를 sm 패널(`sm:<UUID>`)로 찾는 고리.
        env["SM_PANE_ID"] = layoutPane?.id ?? id.uuidString
        if let workspace = layoutPane?.workspace { env["SM_WORKSPACE"] = workspace }
        let set = env.filter { base[$0.key] != $0.value }
        let unset = base.keys.filter { env[$0] == nil }.sorted()
        return (set, unset)
    }

    /// 로그인 셸 인자를 Ghostty 명령 한 줄로. 인자가 없으면 nil(Ghostty가 로그인 셸을 띄운다).
    /// 지울 변수가 있으면 `env -u`로 감싼다 — 표면 설정은 변수를 더하는 것만 받는다.
    static func ghosttyLaunch(arguments: [String], environment: (set: [String: String], unset: [String]),
                              workingDirectory: String,
                              shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        -> GhosttyTerminalView.Launch {
        var words: [String] = []
        if !environment.unset.isEmpty {
            words = ["/usr/bin/env"] + environment.unset.flatMap { ["-u", $0] }
        }
        if !arguments.isEmpty || !words.isEmpty {
            words += [shell] + (arguments.isEmpty ? ["-l"] : arguments)
        }
        let command = words.isEmpty ? nil : words.map(TerminalAttachment.quote).joined(separator: " ")
        return .init(command: command, workingDirectory: workingDirectory, environment: environment.set)
    }

    /// 죽은 탭 재시작 (프로세스 종료·시작 실패 후 재시도)
    func restartIfDead() {
        guard started, terminalView?.isProcessRunning != true, pendingView == nil else { return }
        cancelReconnectTimer()
        startError = nil
        let view = makeTerminal(sizeHint: terminalView?.frame.size)
        guard isReconnecting else {
            replaceTerminal(with: view)
            return
        }
        // 재연결: 새 표면은 화면 밖에서 접속한다. 끊기기 전 화면을 덮지 않다가, 접속이
        // 버티면 바꿔 단다. 한계: "붙었다"를 출력이 아니라 생존 시간으로 판정한다 — 원격이
        // 접속 직후 끊기는 일이 잦으면 holder 메시지(2단계)의 HELLO 응답으로 바꾼다.
        pendingView = view
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.connectedAfter, repeats: false) { [weak self, weak view] _ in
            guard let self, let view, self.pendingView === view, view.isProcessRunning else { return }
            self.pendingView = nil
            self.replaceTerminal(with: view)
            self.connectionResumed()
        }
    }

    /// 재연결한 표면이 이만큼 버티면 붙은 것으로 본다.
    static let connectedAfter: TimeInterval = 1.5

    private func replaceTerminal(with view: GhosttyTerminalView) {
        let old = terminalView
        objectWillChange.send()
        terminalView = view
        // 호스트가 새 표면으로 갈아 끼우며 옛 것을 걷어 낸다. 옛 프로세스는 이미 끝났다.
        DispatchQueue.main.async { old?.terminate() }
    }

    /// 패널 명령의 진짜 종료 코드를 셸이 적는 파일. 터미널은 명령을 login으로 감싸 띄우는데, login은 안쪽이
    /// 어떻게 끝나든 0을 돌려준다(10/31 실측: zsh 255 → login 0). 그래서 끊긴 ssh(255)와 정상 종료를 가르지
    /// 못해, 맥이 잠든 사이 끊긴 아치 패널이 다시 붙지 않았다.
    let exitStatusPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("sm-exit-\(UUID().uuidString)")

    /// 적힌 코드가 있으면 그것(읽고 지운다), 없으면 터미널이 알려 준 코드.
    private func recordedExit(or fallback: Int32) -> Int32 {
        defer { try? FileManager.default.removeItem(atPath: exitStatusPath) }
        guard let text = try? String(contentsOfFile: exitStatusPath, encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return fallback }
        return code
    }

    private func surfaceExited(_ view: GhosttyTerminalView, code reported: Int32, connectedFor: TimeInterval) {
        let code = recordedExit(or: reported)
        if let stageDirectorStorage {
            // 무대가 맡은 패널: 일부러 내린 것인지, 끊겨서 다시 붙어야 하는지는 무대가 안다. 무대가 쉬는 중(내림)이어도
            // 넘긴다 — 그래야 일부러 끝낸 표면의 기록이 지워진다.
            MainActor.assumeIsolated { stageDirectorStorage.surfaceExited(view) }
            return
        }
        if view === pendingView {
            pendingTimer?.invalidate()
            pendingView = nil
            view.terminate()
            handleExit(exitCode: code == 0 ? 255 : code, connectedFor: connectedFor)
            return
        }
        guard view === terminalView else { return }
        isRunning = false
        handleExit(exitCode: code, connectedFor: connectedFor)
    }

    /// PTY 종료 처리. 세션 패널의 attach만 다시 붙이고, 그 동안 터미널 화면은
    /// 끊기기 전 마지막 프레임을 유지한다 (오류 화면으로 바꾸지 않는다). 셸 패널은 끝난 대로 둔다.
    func handleExit(exitCode: Int32, connectedFor: TimeInterval) {
        guard attachesAgent else {
            isReconnecting = false
            return
        }
        let delay = ReconnectPolicy.delay(attempt: reconnectAttempt, connectedFor: connectedFor)
        if connectedFor >= 30 { reconnectAttempt = 0 }
        reconnectAttempt += 1
        isReconnecting = true
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.restartIfDead()
        }
    }

    /// 세션 층의 세션을 보이는 패널인가(`sm-session attach NAME@HOST`, 이 맥이든 다른 기기든).
    private var attachesAgent: Bool {
        if case .agent = attachment { return true }
        return false
    }

    /// 맥이 깨어나면 다시 붙기를 기다리던 패널은 대기를 버리고 곧 다시 시도한다 — 잠든 사이 쌓인 대기
    /// (최대 30초)를 깨자마자 기다리게 하지 않는다. 네트워크가 돌아올 몇 초는 준다.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            if let self, let director = self.stageDirectorStorage, self.stageIsActive {
                MainActor.assumeIsolated { director.reconnectNow() }
                return
            }
            guard let self, self.isReconnecting, self.pendingView == nil else { return }
            self.reconnectAttempt = 0
            self.cancelReconnectTimer()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: Self.afterWake, repeats: false) { [weak self] _ in
                self?.restartIfDead()
            }
        }
    }

    private var wakeObserver: NSObjectProtocol?

    // MARK: 터미널 알림 → Fine 노치

    /// 이 패널의 노치 항목 key. Fine이 자기 탭에 쓰는 모양(`terminal:<탭 UUID>`)과 같다.
    /// 에이전트 패널은 에이전트 이름으로: 앱을 다시 켜도 같은 알림 하나다(UUID였을 땐 켤 때마다 새로 쌓였다).
    var terminalNoticeKey: String {
        if case .agent(let agentName, let host, _) = attachment { return "terminal:" + agentName + "@" + host }
        return "terminal:" + id.uuidString.lowercased()
    }
    private var noticeFields: [String: String]?
    private var noticeInputMonitor: Any?

    /// 터미널 프로그램이 보낸 알림(OSC 9/777)을 Fine 탭처럼 노치에 이 패널의 항목으로 올린다 — 전에는 sm이
    /// 버려서, 같은 프로그램이 Fine 탭에서는 노치에 뜨고 sm 패널에서는 아무 데도 안 떴다. 에이전트 패널이면
    /// 노치를 눌렀을 때 이 패널이 열리도록(`sm reveal`) 그 에이전트를 주소로 단다.
    private func postTerminalNotice(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.isEmpty else { return }
        var fields = ["key": terminalNoticeKey, "title": title.isEmpty ? name : String(title.prefix(300)),
                      "message": String(message.prefix(4000)), "state": "waiting"]
        if case .agent(let agentName, let host, _) = attachment {
            fields["source"] = "sm:" + agentName
            fields["host"] = host
        }
        noticeFields = fields
        MainActor.assumeIsolated { NotchOwner.shared.post(fields) }
        watchInputForNotice()
    }

    /// SEOL이 이 패널에 입력하면 그 알림을 내린다 — seol-notch 알림이 그 칸의 다음 입력에 내려가는 것과 같다.
    /// 알림이 떠 있는 동안에만 키를 엿본다.
    private func watchInputForNotice() {
        guard noticeInputMonitor == nil else { return }
        noticeInputMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, let view = self.terminalView, event.window?.firstResponder === view { self.clearTerminalNotice() }
            return event
        }
    }

    private func stopWatchingInputForNotice() {
        if let noticeInputMonitor { NSEvent.removeMonitor(noticeInputMonitor) }
        noticeInputMonitor = nil
    }

    func clearTerminalNotice() {
        stopWatchingInputForNotice()
        guard var fields = noticeFields else { return }
        noticeFields = nil
        // 노치에서 이미 지웠으면 다시 올리지 않는다(done도 30초 동안 한 줄로 남는다).
        guard PeerDirectory.shared.notices.contains(where: { $0.key == terminalNoticeKey }) else { return }
        fields["state"] = "done"
        fields["message"] = "이어서 진행하고 있어요."
        MainActor.assumeIsolated { NotchOwner.shared.post(fields) }
    }
    static let afterWake: TimeInterval = 3

    /// 새 연결이 원격 화면을 보내기 시작했다 — 배지를 내리고 입력을 다시 받는다.
    func connectionResumed() {
        guard isReconnecting else { return }
        isReconnecting = false
    }

    var acceptsInput: Bool { !isReconnecting }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// 죽은 연결을 복구한다. 살아 있는 세션은 건드리지 않는다.
    func reconnectIfNeeded() {
        if let stageDirectorStorage, stageIsActive {
            MainActor.assumeIsolated { stageDirectorStorage.reconnectNow() }
            return
        }
        _ = getOrCreateTerminal()
        restartIfDead()
    }

    static func defaultShellName(remoteHost: String?) -> String {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return "zsh" }
        return "shell@\(host)"
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let director = self.stageDirectorStorage {
                // 포커스가 왔다 = 보이는 패널이다. 내려 둔 채였으면 다시 붙인다(키는 무대가 붙잡았다가 넘긴다).
                MainActor.assumeIsolated {
                    if !director.isActive { director.begin() }
                    director.stage.focus()
                }
                return
            }
            self.terminalView?.focusTerminal()
        }
    }

    func cleanup(force: Bool = false) {
        if let stageDirectorStorage { MainActor.assumeIsolated { stageDirectorStorage.end() } }
        started = false
        stopWatchingInputForNotice()
        cancelReconnectTimer()
        isReconnecting = false
        try? FileManager.default.removeItem(atPath: exitStatusPath)
        pendingTimer?.invalidate()
        pendingView?.terminate()
        pendingView = nil
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    deinit {
        if let noticeInputMonitor { NSEvent.removeMonitor(noticeInputMonitor) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        reconnectTimer?.invalidate()
        pendingTimer?.invalidate()
        try? FileManager.default.removeItem(atPath: exitStatusPath)
    }

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
}

/// A pane showing a session-layer session (`sm-session attach NAME@HOST`) is attached again whenever its
/// attach ends, whatever the code. The attach itself no longer ends when the session stops or sleeps: it
/// keeps the last screen and waits for a key in that pane (11/01). So an attach that ended
/// was cut from outside — ssh dropped while the Mac slept, the process was killed when SEOL shut sessions
/// down for quota — and the pane would otherwise stay dead. Attaching again never starts the session by
/// itself, so this cannot spend quota. A closed pane is not retried (cleanup stops it first).
/// Retries back off while a host sleeps.
enum ReconnectPolicy {
    static func delay(attempt: Int, connectedFor: TimeInterval) -> TimeInterval {
        min(30, 3 * pow(2, Double(connectedFor >= 30 ? 0 : min(4, max(0, attempt)))))
    }
}
