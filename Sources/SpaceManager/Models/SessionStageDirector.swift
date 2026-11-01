import AppKit
import Foundation
import GhosttyTerminal

/// 세션 층의 세션을 보이는 패널의 무대 감독(SEOL 11/01, `~/cld/agent-relay/briefs/sleep-wake-ux.md`).
///
/// 잠들거나 멈춘 세션의 패널은 빈 화면이 아니라 마지막 화면 위에 어두운 막을 얹어 보인다. 보면 깨기 시작하고
/// (세션 층은 attach가 열리면 깨운다), 깨는 동안 막이 숨쉬며, 새 attach가 화면을 다 채우고 조용해지면 막과
/// 장면을 함께 걷어 그 자리에서 입력을 받는다. Claude가 다시 뜨며 화면을 채우는 순간은 보이지 않는다.
///
/// 그리는 것은 공용 패키지의 `GhosttySessionStage`가 하고, 이 감독은 세션 층의 상태 스트림
/// (`sm-session state NAME@HOST --watch --json`: asleep|stopped|waking|ready|tmux|gone)을 보고 언제 얼리고
/// 깔고 걷을지를 정한다. attach는 `--no-screen`으로 띄운다 — 마지막 화면은 앱이 그린다.
@MainActor
final class SessionStageDirector {
    /// 끄는 길: `defaults write com.spacemanager.app sessionStage -bool NO` → 예전처럼 attach 표면을 바로 보인다.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "sessionStage") as? Bool ?? true }

    let stage = GhosttySessionStage(frame: .zero)
    let target: String
    /// 새 attach 표면을 만든다(TerminalSession.makeTerminal, `--no-screen`).
    var makeSurface: () -> GhosttyTerminalView
    /// 지금 입력을 받는 표면이 바뀌었다(TerminalSession.terminalView를 맞춘다).
    var onLiveChange: (GhosttyTerminalView?) -> Void = { _ in }
    /// 다시 붙는 중인가(재연결 배지).
    var onReconnecting: (Bool) -> Void = { _ in }
    /// 시험에서 세션 층 대신.
    var sessionLayer = SessionLayer.executable

    private(set) var state: String?
    private(set) var isActive = false
    private var watcher: Process?
    private var watchRestart: DispatchWorkItem?
    private var reconnect: DispatchWorkItem?
    private var reconnectAttempt = 0
    /// 일부러 내린 attach(멈춤·가려짐) — 그 끝남은 끊김이 아니다.
    private var endedOnPurpose = Set<ObjectIdentifier>()
    /// 얼린 화면 아래에서 다시 붙는 동안, 오래 걸리면 "연결 중" 모습으로 바꾸는 예약.
    private var connectingLook: DispatchWorkItem?
    /// 빠르게 다시 붙으면(대부분) 막도 빛도 없이 얼린 화면이 그대로 걷힌다. 이보다 오래 걸릴 때만 "연결 중"을 보인다
    /// — 탭을 오갈 때마다 빛이 번쩍이면 오히려 거슬린다.
    static let connectingAfter: TimeInterval = 0.3

    init(target: String, makeSurface: @escaping () -> GhosttyTerminalView) {
        self.target = target
        self.makeSurface = makeSurface
        stage.onKeyWhileResting = { [weak self] in self?.wakeByKey() }
        stage.onReveal = { [weak self] in
            guard let self else { return }
            self.reconnectAttempt = 0
            self.connectingLook?.cancel()
            self.connectingLook = nil
            self.stage.caption = nil
            self.onReconnecting(false)
        }
    }

    // MARK: 패널이 보이고 가려질 때

    /// 패널이 보이기 시작했다(처음, 또는 가려졌다 다시). 상태를 받으면 무엇을 보일지 정한다.
    func begin() {
        guard !isActive else { return }
        isActive = true
        state = nil
        watch()
    }

    /// 오래 가려졌다: attach를 내리고 마지막 화면을 장면으로 남긴다(세션 층이 그 워크스페이스를 재울 수 있게).
    /// 다시 보이면 그 장면 아래에 새 attach를 깔고, 조용해지면 걷는다 — 다시 붙는 순간이 보이지 않는다.
    func park() {
        guard isActive else { return }
        isActive = false
        stopWatch()
        cancelReconnect()
        cancelConnectingLook()
        if let live = stage.live { endOnPurpose(live) }
        stage.freeze(look: .clear)
        onLiveChange(nil)
        state = nil
    }

    /// 패널을 닫았다.
    func end() {
        isActive = false
        stopWatch()
        cancelReconnect()
        cancelConnectingLook()
        stage.clear()
        onLiveChange(nil)
        state = nil
    }

    // MARK: 상태

    func apply(_ next: String) {
        guard isActive else { return }
        let previous = state
        state = next
        switch next {
        case "ready", "tmux":
            if stage.live == nil { open() }
            if stage.isCovered { stage.revealWhenQuiet() }
        case "waking":
            if stage.live == nil { open() }
            stage.caption = nil
            stage.setLook(.waking)
        case "asleep", "stopped", "gone":
            if previous == nil || stage.live == nil && !stage.isCovered {
                // 처음 본다: 마지막 화면부터. 보는 것이 곧 깨우기다(세션 층은 attach가 열리면 깨운다).
                showLastScreen { [weak self] in
                    guard let self, self.isActive, next != "gone" else { return }
                    self.open()
                    self.stage.setLook(.waking)
                }
            } else if let live = stage.live, !stage.isCovered || stage.look == .waking {
                // 보는 중에 누가 멈췄다(쿼타): 그 화면을 얼리고 키를 기다린다. 저절로 깨우지 않는다.
                if stage.isCovered { stage.cancelAttach() } else { endOnPurpose(live); stage.freeze(look: .dimmed) }
                onLiveChange(nil)
                stage.caption = next == "gone" ? "세션이 없습니다" : "멈춤 · 아무 키나 누르면 이어서"
            }
        default:
            break
        }
    }

    /// 멈춘 세션의 막 아래에서 키를 눌렀다 — 깨운다(키는 무대가 붙잡았다가 걷힐 때 넘긴다).
    private func wakeByKey() {
        guard isActive, state != "gone" else { return }
        stage.caption = nil
        if stage.live == nil { open() }
        stage.setLook(.waking)
    }

    // MARK: attach 표면

    /// 새 attach를 장면 아래에 깐다. 세션이 쓸 수 있는 상태면 조용해지는 대로 걷는다.
    private func open() {
        let view = makeSurface()
        stage.attach(view)
        onLiveChange(view)
        if state == "ready" || state == "tmux" { stage.revealWhenQuiet() }
        // 얼린 화면 아래에서 다시 붙는 중(가려졌다 다시 봄): 오래 걸리면 깨울 때와 같은 "연결 중" 모습.
        if stage.isCovered && stage.look == .clear { scheduleConnectingLook() }
    }

    private func scheduleConnectingLook() {
        cancelConnectingLook()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.stage.isCovered, self.stage.look == .clear else { return }
            self.stage.setLook(.waking)
        }
        connectingLook = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectingAfter, execute: work)
    }

    private func cancelConnectingLook() {
        connectingLook?.cancel()
        connectingLook = nil
    }

    /// 표면의 자식(attach)이 끝났다.
    func surfaceExited(_ view: GhosttyTerminalView) {
        if endedOnPurpose.remove(ObjectIdentifier(view)) != nil { return }
        guard isActive, view === stage.live else { return }
        // 밖에서 끊겼다(ssh — 맥이 잠들었거나 연결이 오래 조용했다, 강제 종료). 마지막 화면을 얼리고 깨울 때와
        // 같은 "연결 중" 모습으로 둔 채 다시 붙는다(SEOL 11/01). 세션 층의 attach는 세션이 멈추거나 잠들어도
        // 끝나지 않으므로, 끝났다면 다시 붙는 것이 맞다. 끊긴 동안은 세션 층에 물을 수 없어 이 상태는 앱이 정한다.
        stage.freeze(look: .waking)
        stage.caption = "다시 연결하는 중"
        onLiveChange(nil)
        onReconnecting(true)
        let delay = min(30, 3 * pow(2, Double(min(4, reconnectAttempt))))
        reconnectAttempt += 1
        scheduleReconnect(after: delay)
    }

    /// 재연결 배지를 눌렀다: 기다리지 않고 지금.
    func reconnectNow() {
        guard isActive, stage.live == nil else { return }
        scheduleReconnect(after: 0)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        cancelReconnect()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.stage.live == nil else { return }
            self.open()
        }
        reconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelReconnect() {
        reconnect?.cancel()
        reconnect = nil
    }

    private func endOnPurpose(_ view: GhosttyTerminalView) {
        endedOnPurpose.insert(ObjectIdentifier(view))
        view.endProcess()
    }

    // MARK: 마지막 화면

    /// 장면이 없으면 세션 층이 남긴 마지막 화면을 깐다(없으면 빈 바탕 위의 막). 그다음 `then`.
    private func showLastScreen(then: @escaping () -> Void) {
        guard !stage.hasFrame else {
            stage.freeze(look: .dimmed)
            then()
            return
        }
        let executable = sessionLayer, target = target
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.run(executable, ["screen", target])
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if let data, !data.isEmpty, !self.stage.hasFrame {
                        self.stage.freeze(replaying: data, look: .dimmed)
                    } else {
                        self.stage.freeze(look: .dimmed)
                    }
                    then()
                }
            }
        }
    }

    // MARK: 상태 스트림

    private func watch() {
        stopWatch()
        var heardAny = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sessionLayer)
        process.arguments = ["state", target, "--watch", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = UserShellEnvironment.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let pending = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for line in pending.lines(adding: chunk) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let state = object["state"] as? String else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { heardAny = true; self?.apply(state) } }
            }
        }
        process.terminationHandler = { [weak self] _ in
            // ssh가 끊기는 등으로 스트림이 끝났다. 보이는 동안이면 다시 듣는다.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive, self.watcher === process else { return }
                    // 상태를 하나도 못 받았다: 이 기기의 세션 층이 상태 스트림을 모른다(옛 판). 예전처럼 바로 붙어 보인다.
                    if !heardAny, self.state == nil {
                        self.state = "ready"
                        if self.stage.live == nil { self.open() }
                        self.stage.reveal(animated: false)
                        return
                    }
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.isActive else { return }
                        self.watch()
                    }
                    self.watchRestart = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
                }
            }
        }
        do {
            try process.run()
        } catch {
            // 세션 층을 띄우지 못했다(배포 중에 파일이 잠깐 없었다 등). 보이는 동안 다시 시도한다 — 그냥 돌아가면
            // 켜진 채로 아무것도 듣지 않아, 패널이 앱을 다시 켤 때까지 텅 빈 채였다(11/01 sm-front 워크스페이스).
            output.fileHandleForReading.readabilityHandler = nil
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive else { return }
                self.watch()
            }
            watchRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        watcher = process
    }

    private func stopWatch() {
        watchRestart?.cancel()
        watchRestart = nil
        if let watcher, watcher.isRunning { watcher.terminate() }
        watcher = nil
    }

    /// 읽기 손잡이 하나에서만 쓰는 줄 모음(읽기 콜백은 한 큐에서 차례로 온다).
    private final class LineBuffer: @unchecked Sendable {
        private var data = Data()
        func lines(adding chunk: Data) -> [Data] {
            data.append(chunk)
            var lines: [Data] = []
            while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(data[data.startIndex..<newline]))
                data.removeSubrange(data.startIndex...newline)
            }
            return lines
        }
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = UserShellEnvironment.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
