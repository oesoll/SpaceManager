import Foundation

/// 한 기기의 세션 상태 스트림 하나를 모든 패널이 나눠 쓴다(`sm-session state - --watch --host HOST`).
///
/// 전에는 보이는 패널마다 `state NAME@HOST --watch`를 따로 띄웠다. 패널이 열네 개면 Python 열네 개(175MB)가
/// 저마다 2초마다 peer 기록을 전부 읽었고, 재부팅 직후 맥의 Python 시간 대부분이 여기서 나왔다(11/16 실측).
/// 이제 기기마다 프로세스 하나가 `+NAME`/`-NAME` 줄로 볼 이름을 받고, 줄마다 이름을 보고 그 패널들에 나눠 준다.
///
/// 옛 세션 층(`state -`를 모른다)이면 프로세스가 아무 줄 없이 곧 끝난다. 그때는 구독자에게 알려 예전처럼
/// 패널마다 감시하게 한다(`onUnsupported`).
@MainActor
final class SessionStateHub {
    typealias Handler = (String) -> Void

    private struct Subscriber {
        let onState: Handler
        let onUnsupported: () -> Void
    }

    private static var hubs: [String: SessionStateHub] = [:]

    /// 기기(그리고 시험에서 바꿔 끼운 세션 층 실행 파일)마다 하나.
    static func shared(host: String, executable: String) -> SessionStateHub {
        let key = executable + "\u{0}" + host
        if let hub = hubs[key] { return hub }
        let hub = SessionStateHub(host: host, executable: executable)
        hubs[key] = hub
        return hub
    }

    /// 시험: 모든 기기의 감시를 끝낸다 — 시험마다 가짜 세션 층이 바뀌는데, 앞 시험의 프로세스를 이어 쓰면 안 된다.
    static func stopAll() {
        hubs.values.forEach { $0.subscribers = [:]; $0.stop() }
        hubs = [:]
    }

    let host: String
    let executable: String
    private var subscribers: [String: [UUID: Subscriber]] = [:]
    /// 이름마다 마지막으로 들은 상태 — 같은 세션을 두 번째로 보는 패널은 다음 줄을 기다리지 않고 바로 받는다.
    private var last: [String: String] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var restart: DispatchWorkItem?
    private var idleStop: DispatchWorkItem?
    private(set) var unsupported = false

    private init(host: String, executable: String) {
        self.host = host
        self.executable = executable
    }

    func subscribe(_ name: String, onState: @escaping Handler, onUnsupported: @escaping () -> Void) -> UUID {
        let id = UUID()
        if unsupported {
            DispatchQueue.main.async { onUnsupported() }
            return id
        }
        let first = subscribers[name]?.isEmpty ?? true
        subscribers[name, default: [:]][id] = Subscriber(onState: onState, onUnsupported: onUnsupported)
        idleStop?.cancel()
        idleStop = nil
        if process == nil {
            start()
        } else if first {
            send("+" + name)
        } else if let state = last[name] {
            DispatchQueue.main.async { onState(state) }
        }
        return id
    }

    func unsubscribe(_ name: String, _ id: UUID) {
        guard subscribers[name]?.removeValue(forKey: id) != nil else { return }
        guard subscribers[name]?.isEmpty ?? true else { return }
        subscribers[name] = nil
        last[name] = nil
        send("-" + name)
        if subscribers.isEmpty { scheduleIdleStop() }
    }

    // MARK: 프로세스

    private func start() {
        restart?.cancel()
        restart = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["state", "-", "--watch", "--host", host]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = UserShellEnvironment.path
        process.environment = environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        let pending = LineBuffer()
        var heardAny = false
        let started = Date()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let rows = pending.lines(adding: chunk).compactMap { line -> (String, String)? in
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let name = object["name"] as? String, let state = object["state"] as? String else { return nil }
                return (name, state)
            }
            guard !rows.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    heardAny = true
                    rows.forEach { self?.deliver(name: $0.0, state: $0.1) }
                }
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === process else { return }
                    self.process = nil
                    self.input = nil
                    guard !self.subscribers.isEmpty else { return }
                    // 줄 하나 없이 인자 오류(2)로 곧 끝났다: 이 기기의 세션 층이 `state -`를 모른다(옛 판).
                    // ssh가 닿지 않은 것(255 — 아치가 잠들었거나 부팅 직후 네트워크가 아직 없다)은 옛 판이 아니다:
                    // 그렇게 보면 앱을 다시 켤 때까지 패널마다 따로 감시했다. 그때는 아래처럼 다시 붙는다.
                    if !heardAny, status == 2, Date().timeIntervalSince(started) < 10 {
                        self.unsupported = true
                        let waiting = self.subscribers.values.flatMap(\.values)
                        self.subscribers = [:]
                        waiting.forEach { $0.onUnsupported() }
                        return
                    }
                    // ssh가 끊기는 등으로 끝났다. 보는 이름이 남아 있으면 다시 듣는다.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.process == nil, !self.subscribers.isEmpty else { return }
                        self.start()
                    }
                    self.restart = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
                }
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.process == nil, !self.subscribers.isEmpty else { return }
                self.start()
            }
            restart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        subscribers.keys.sorted().forEach { send("+" + $0) }
    }

    private func send(_ line: String) {
        guard let input else { return }
        // 끝난 프로세스에 쓰면 SIGPIPE 대신 오류가 난다(Foundation이 막는다) — 그때는 재시작이 이름을 다시 보낸다.
        try? input.write(contentsOf: Data((line + "\n").utf8))
    }

    private func deliver(name: String, state: String) {
        guard let listeners = subscribers[name] else { return }
        last[name] = state
        listeners.values.forEach { $0.onState(state) }
    }

    /// 아무도 보지 않으면 잠시 뒤 끝낸다 — 탭을 오가며 0개가 되는 순간마다 끝냈다 다시 띄우지 않게.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.subscribers.isEmpty else { return }
            self.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func stop() {
        restart?.cancel()
        restart = nil
        let process = self.process
        self.process = nil
        try? input?.close()   // 표준입력이 닫히면 감시가 스스로 끝난다(원격이면 ssh와 함께)
        input = nil
        if let process, process.isRunning { process.terminate() }
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
}
