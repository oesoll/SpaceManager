import Foundation
import SwiftUI
import Combine

enum TabKind: String, Codable {
    case tmuxMain    // 워크스페이스 고정 탭 — 워크스페이스 tmux 세션에 attach
    case shell       // 순수 셸 탭 — 앱 재시작 시 새 셸로 시작 (복구 없음, 명시적 한계)
    case tmuxExtra   // 추가 tmux 탭 — <세션명>-N, 재부팅 후에도 복구됨
    case quick       // 홈에서 로그인 셸로 ccv를 직접 실행하는 일회성 대화 PTY
}

/// 터미널 탭 하나. libghostty 표면(PTY와 프로세스를 쥔다)을 소유해
/// SwiftUI 뷰 업데이트를 넘어 터미널을 살아있게 한다 (기존 세션 소유 패턴 계승).
final class TerminalSession: Identifiable, ObservableObject, Equatable {
    let id: UUID
    let kind: TabKind
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var startError: String?
    /// 원격 tmux 연결이 끊겨 다시 붙는 중. 새 연결이 첫 출력을 보낼 때까지 유지된다 —
    /// ssh 접속(프록시 경유 수 초) 동안에도 화면은 끊기기 전 그대로 두고 배지만 띄운다.
    @Published private(set) var isReconnecting = false
    /// 마지막으로 실패한 연결에서 ssh가 남긴 한 줄. 배지 툴팁에만 쓴다.
    @Published private(set) var lastConnectionFailure: String?
    var workingDirectory: String
    /// tmuxMain/tmuxExtra가 attach할 세션명 (shell이면 nil)
    let tmuxSessionName: String?
    /// ssh 호스트 별칭. 설정되면 tmux 서버(또는 셸)가 그 호스트에서 돈다.
    let remoteHost: String?
    let quickLaunch: QuickLaunch?
    let quickConfiguration: QuickSessionConfiguration
    /// 셸 패널이 무엇에 붙는가(로그인 셸 또는 peer holder의 에이전트). 붙이는 방법은 TerminalAttachment에만 있다.
    let attachment: TerminalAttachment
    /// 배치 데이터의 패널이면 그 id(`p-…`)와 워크스페이스. 패널 안 셸이 `sm split`처럼 자기 자리를 알게
    /// `SM_PANE_ID`·`SM_WORKSPACE`로 넘긴다(세션 층 계약). 없으면 탭 id를 `SM_PANE_ID`로 쓴다.
    var layoutPane: (id: String, workspace: String)?
    private let initialName: String

    /// 지금 화면에 붙은 터미널. libghostty 표면이 PTY와 자식 프로세스를 직접 쥔다.
    private(set) var terminalView: GhosttyTerminalView?
    /// 작업 창의 라이트/다크를 따른다. 터미널이 아직 없으면 만들 때 이 값을 쓴다.
    /// 화면이 다시 그려질 때마다 같은 값이 다시 들어온다 — 바뀐 때만 표면 설정을 다시 건다.
    var palette: TerminalPalette {
        didSet { if palette != oldValue { terminalView?.setPalette(palette) } }
    }
    private var started = false
    private var quickSessionId: String?
    private var quickIdentityTimer: Timer?
    private var quickTitleCancellable: AnyCancellable?
    private var isTrackingQuickTitle = false
    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0
    /// 재연결 중 새로 띄운 표면. 붙었다고 볼 때까지 화면에는 끊기기 전 표면을 그대로 둔다.
    private var pendingView: GhosttyTerminalView?
    private var pendingTimer: Timer?
    /// 원격 tmux 탭의 ssh stderr. 탭 id가 아니라 객체마다 따로 둔다 — 호스트 전환은 같은
    /// id로 새 세션을 만들기 때문에, 옛 객체가 정리되며 새 객체의 로그를 지우면 안 된다.
    let sshErrorLogPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("space-manager-ssh-\(UUID().uuidString).log")

    init(id: UUID = UUID(), kind: TabKind, name: String,
         workingDirectory: String, tmuxSessionName: String? = nil,
         remoteHost: String? = nil,
         quickLaunch: QuickLaunch? = nil,
         quickConfiguration: QuickSessionConfiguration = .default,
         attachment: TerminalAttachment = .shell) {
        self.attachment = attachment
        self.id = id
        self.kind = kind
        self.palette = kind == .quick ? .quickLight : .workspaceDark
        self.name = name
        self.initialName = name
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
        self.remoteHost = remoteHost
        self.quickLaunch = quickLaunch
        self.quickConfiguration = quickConfiguration
        self.quickSessionId = quickLaunch?.resumeSessionId
    }

    /// 화면에 붙일 터미널. 처음 부르는 순간 프로세스가 뜬다.
    func getOrCreateTerminal() -> GhosttyTerminalView {
        if let existing = terminalView { return existing }
        started = true
        let view = makeTerminal()
        terminalView = view
        return view
    }

    /// Quick은 클릭 순간 Claude를 띄운다. 표면은 창에 붙기 전에도 프로세스를 돌린다.
    func startQuickImmediately() {
        guard kind == .quick else { return }
        _ = getOrCreateTerminal()
    }

    /// 이 탭의 명령으로 새 표면을 만든다(= 새 프로세스).
    /// `sizeHint`: 재연결할 때 끊긴 표면의 크기. 없으면(처음) 창에 들어가 크기를 안 뒤에 띄운다.
    /// Quick은 클릭 순간 Claude를 띄워야 해서 기다리지 않는다.
    private func makeTerminal(sizeHint: NSSize? = nil) -> GhosttyTerminalView {
        cancelReconnectTimer()
        if kind == .quick {
            workingDirectory = QuickSessionPolicy.ensureWorkingDirectory()
        }
        let startDir = FileManager.default.fileExists(atPath: workingDirectory)
            ? workingDirectory : NSHomeDirectory()
        let launch = Self.ghosttyLaunch(
            arguments: launchArguments(startDirectory: startDir),
            environment: launchEnvironment(),
            workingDirectory: startDir)
        let hint = sizeHint.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let view = GhosttyTerminalView(launch: launch, palette: palette, startWhenSized: kind != .quick, initialSize: hint)
        view.translatesAutoresizingMaskIntoConstraints = false
        let launchedAt = Date()
        view.onExit = { [weak self, weak view] code in
            guard let self, let view, self.started else { return }
            self.surfaceExited(view, code: code, connectedFor: Date().timeIntervalSince(launchedAt))
        }
        if view.failedToStart {
            startError = "터미널을 시작하지 못했습니다 (libghostty 표면 생성 실패)"
            isRunning = false
        } else {
            startError = nil
            isRunning = true
            if kind == .quick { beginQuickTitleUpdates(view: view) }
        }
        return view
    }

    private func launchArguments(startDirectory: String) -> [String] {
        if kind == .shell, let command = attachment.command() {
            return ["-lc", command]
        }
        return Self.launchArguments(
            kind: kind,
            tmuxSessionName: tmuxSessionName,
            workingDirectory: startDirectory,
            remoteHost: remoteHost,
            // 원격 디렉토리는 폴백 전 원래 경로에서 계산한다 — 로컬에 없어도 원격엔 있다.
            remoteDirectory: TmuxBootstrap.remoteDirectory(forLocalPath: workingDirectory),
            quickLaunch: quickLaunch,
            quickConfiguration: quickConfiguration,
            sshErrorLog: sshErrorLogPath
        )
    }

    /// 앱 환경에서 바꿀 것만(더할 값, 지울 이름). TERM·COLORTERM은 Ghostty 설정이 준다.
    private func launchEnvironment() -> (set: [String: String], unset: [String]) {
        let base = ProcessInfo.processInfo.environment
        var env = base
        // peer가 이 터미널의 에이전트를 sm 패널(`sm:<UUID>`)로 찾는 고리. tmux 탭에는 넣지 않는다 —
        // 새로 뜨는 tmux 서버가 전역 환경으로 물려받아 모든 패널이 이 탭을 자기 것이라 주장한다.
        if kind == .shell {
            env["SM_PANE_ID"] = layoutPane?.id ?? id.uuidString
            if let workspace = layoutPane?.workspace { env["SM_WORKSPACE"] = workspace }
        }
        if kind == .quick {
            env = QuickSessionPolicy.applyingEnvironment(env, launch: quickLaunch ?? .blank,
                                                         configuration: quickConfiguration)
        }
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

    /// Quick 탭 제목. 표면의 앞 프로세스(claude)의 pid로 대화 id를 찾는다 — Claude가 등록부를
    /// 쓰기까지 잠깐 걸리므로 1초마다 다시 본다.
    private func beginQuickTitleUpdates(view: GhosttyTerminalView) {
        let scanner = QuickConversationScanner.shared
        if isTrackingQuickTitle { scanner.untrack(owner: id) }
        isTrackingQuickTitle = false
        if quickLaunch?.resumeSessionId == nil {
            quickSessionId = nil
            name = initialName
        }
        quickTitleCancellable = scanner.$aiTitlesBySessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] titles in
                self?.updateQuickTitle(titlesBySessionId: titles)
            }
        scanner.start()
        trackQuickTitle()
        scanner.rescan()

        guard quickSessionId == nil else { return }
        quickIdentityTimer?.invalidate()
        quickIdentityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] timer in
            guard let self, let view, self.isRunning else {
                timer.invalidate()
                return
            }
            if let pid = view.foregroundProcessIdentifier {
                self.resolveQuickSessionId(processIdentifier: pid)
            }
            if self.quickSessionId != nil {
                timer.invalidate()
                self.quickIdentityTimer = nil
            }
        }
    }

    private func resolveQuickSessionId(processIdentifier: pid_t) {
        guard quickSessionId == nil,
              let sessionId = QuickSessionTitleResolver.sessionId(
                processIdentifier: processIdentifier
              ) else { return }
        quickSessionId = sessionId
        trackQuickTitle()
        updateQuickTitle(
            titlesBySessionId: QuickConversationScanner.shared.aiTitlesBySessionId
        )
        QuickConversationScanner.shared.rescan()
    }

    private func trackQuickTitle() {
        guard let quickSessionId else { return }
        QuickConversationScanner.shared.track(sessionID: quickSessionId, owner: id)
        isTrackingQuickTitle = true
    }

    func updateQuickTitle(titlesBySessionId: [String: String]) {
        guard kind == .quick,
              let quickSessionId,
              let title = titlesBySessionId[quickSessionId] else { return }
        name = title
    }

    func matchesQuickConversation(sessionId: String) -> Bool {
        kind == .quick && quickSessionId == sessionId
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

    private func surfaceExited(_ view: GhosttyTerminalView, code: Int32, connectedFor: TimeInterval) {
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

    /// PTY 종료 처리. 원격 tmux의 비정상 종료만 재연결하고, 그 동안 터미널 화면은
    /// 끊기기 전 마지막 프레임을 유지한다 (오류 화면으로 바꾸지 않는다).
    func handleExit(exitCode: Int32, connectedFor: TimeInterval) {
        guard let delay = RemoteReconnectPolicy.delay(kind: kind, remoteHost: remoteHost,
            exitCode: exitCode, attempt: reconnectAttempt, connectedFor: connectedFor) else {
            // detach(0)처럼 의도된 종료는 재시도 배지를 남기지 않는다.
            isReconnecting = false
            return
        }
        if connectedFor >= 30 { reconnectAttempt = 0 }
        reconnectAttempt += 1
        lastConnectionFailure = Self.lastLogLine(at: sshErrorLogPath) ?? lastConnectionFailure
        isReconnecting = true
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.restartIfDead()
        }
    }

    /// 새 연결이 원격 화면을 보내기 시작했다 — 배지를 내리고 입력을 다시 받는다.
    func connectionResumed() {
        guard isReconnecting else { return }
        isReconnecting = false
        lastConnectionFailure = nil
    }

    var acceptsInput: Bool { !isReconnecting }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// ssh 로그의 마지막 비어 있지 않은 줄. 접속마다 `2>`로 새로 쓰므로 직전 시도의 원인이다.
    static func lastLogLine(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data.suffix(4096), encoding: .utf8) ?? String(data: data.suffix(4096), encoding: .isoLatin1) else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map { String($0.prefix(240)) }
    }

    /// CLI도 화면 선택과 같은 경로로 죽은 연결을 복구한다. 실행 중인 tmux는 건드리지 않는다.
    func reconnectIfNeeded() {
        _ = getOrCreateTerminal()
        restartIfDead()
    }

    func retargeted(to host: String?) -> TerminalSession {
        // 셸 탭 이름은 실행 위치를 말한다 ("zsh" / "shell@arch"). 위치가 바뀌면 함께 바꾼다.
        let retargetedName = kind == .shell && name == Self.defaultShellName(remoteHost: remoteHost)
            ? Self.defaultShellName(remoteHost: host) : name
        return TerminalSession(id: id, kind: kind, name: retargetedName, workingDirectory: workingDirectory,
                               tmuxSessionName: tmuxSessionName, remoteHost: host,
                               quickLaunch: quickLaunch, quickConfiguration: quickConfiguration)
    }

    static func defaultShellName(remoteHost: String?) -> String {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return "zsh" }
        return "shell@\(host)"
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.focusTerminal()
        }
    }

    func cleanup(force: Bool = false) {
        started = false
        cancelReconnectTimer()
        isReconnecting = false
        try? FileManager.default.removeItem(atPath: sshErrorLogPath)
        if isTrackingQuickTitle { QuickConversationScanner.shared.untrack(owner: id) }
        isTrackingQuickTitle = false
        quickIdentityTimer?.invalidate()
        quickIdentityTimer = nil
        quickTitleCancellable = nil
        pendingTimer?.invalidate()
        pendingView?.terminate()
        pendingView = nil
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    deinit {
        reconnectTimer?.invalidate()
        pendingTimer?.invalidate()
        try? FileManager.default.removeItem(atPath: sshErrorLogPath)
        quickIdentityTimer?.invalidate()
        if isTrackingQuickTitle { QuickConversationScanner.shared.untrack(owner: id) }
    }

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }

    /// PTY 실행 정책을 순수 함수로 분리해 Quick이 TmuxBootstrap을 절대 거치지
    /// 않는다는 경계를 테스트할 수 있게 한다.
    static func launchArguments(
        kind: TabKind,
        tmuxSessionName: String?,
        workingDirectory: String,
        remoteHost: String? = nil,
        remoteDirectory: TmuxBootstrap.RemoteDirectory? = nil,
        quickLaunch: QuickLaunch? = nil,
        quickConfiguration: QuickSessionConfiguration = .default,
        sshErrorLog: String? = nil
    ) -> [String] {
        if kind == .quick {
            return ["-lc", QuickSessionPolicy.launchCommand(
                for: quickLaunch ?? .blank,
                configuration: quickConfiguration
            )]
        }
        // 원격: 로컬 셸은 ssh만 exec한다. tmux 콜드부트 판단은 원격 스크립트가 한다.
        if let remoteHost, !remoteHost.trimmingCharacters(in: .whitespaces).isEmpty {
            let dir = remoteDirectory ?? TmuxBootstrap.remoteDirectory(forLocalPath: workingDirectory)
            if let tmuxSessionName {
                let script = TmuxBootstrap.remoteStartupScript(sessionName: tmuxSessionName, remoteDirectory: dir)
                return ["-lc", TmuxBootstrap.remoteLaunchCommand(host: remoteHost, remoteScript: script, errorLog: sshErrorLog)]
            }
            return ["-lc", TmuxBootstrap.remoteShellCommand(host: remoteHost, remoteDirectory: dir)]
        }
        if let tmuxSessionName {
            return ["-lc", TmuxBootstrap.startupScript(
                sessionName: tmuxSessionName,
                workingDirectory: workingDirectory
            )]
        }
        return []   // 순수 인터랙티브 로그인 셸
    }
}

/// Only a persistent remote tmux attachment is retried. A deliberate detach (0),
/// a shell exit or a Quick conversation must stay closed. Cap retries while a host sleeps.
enum RemoteReconnectPolicy {
    static func delay(kind: TabKind, remoteHost: String?, exitCode: Int32,
                      attempt: Int, connectedFor: TimeInterval) -> TimeInterval? {
        guard kind == .tmuxMain || kind == .tmuxExtra,
              let remoteHost, !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              exitCode != 0 else { return nil }
        let failures = connectedFor >= 30 ? 0 : min(4, max(0, attempt))
        return min(30, 3 * pow(2, Double(failures)))
    }
}

/// PTY io 큐에서만 만지는 일회성 플래그 — 첫 출력에서 한 번만 메인으로 알린다.
private final class FirstOutputLatch {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

private extension QuickLaunch {
    var resumeSessionId: String? {
        guard case .resume(let sessionId) = self else { return nil }
        return sessionId
    }
}

extension TerminalSession {
    convenience init(snapshot: TabSnapshot) {
        self.init(id: snapshot.id, kind: snapshot.kind, name: snapshot.name,
                  workingDirectory: snapshot.workingDirectory,
                  tmuxSessionName: snapshot.tmuxSessionName,
                  remoteHost: snapshot.remoteHost)
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, kind: kind, name: name,
                    workingDirectory: workingDirectory,
                    tmuxSessionName: tmuxSessionName,
                    remoteHost: remoteHost)
    }
}
