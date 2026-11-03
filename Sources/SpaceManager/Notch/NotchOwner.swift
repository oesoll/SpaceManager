import AppKit
import Combine
import Foundation

/// 노치를 누가 그리는가, 그리고 알림이 들어오는 입구.
///
/// 노치는 Fine에 있다가 sm으로 옮겨 온다(11/01, SEOL 승인: "노티파이도 sm으로 일괄"). 옮기는 동안 노치가 둘이거나
/// 없는 순간이 없어야 해서, 입구는 지금부터 sm 하나로 두고 그리는 쪽만 넘긴다:
/// - Fine이 아직 노치를 가진 동안(`attention.status`에 답하는 동안) sm은 받은 명령을 그대로 Fine에 넘긴다.
/// - Fine이 "unknown command"로 답하면(노치를 걷어 낸 Fine) sm이 이어받는다. Fine 파일에서 아직 떠 있는 알림을
///   가져오고, 그 뒤로는 sm이 노치를 그린다. 한 번 넘겨받으면 되돌리지 않는다(`~/.space-manager/notch-owner`).
/// Fine이 꺼져 있는 동안은 아직 정해지지 않은 것으로 보고 기다린다 — 옛 Fine이 다시 뜨면 노치가 둘이 된다.
@MainActor
final class NotchOwner: ObservableObject {
    static let shared = NotchOwner()

    enum Owner: String { case fine, sm }
    @Published private(set) var owner: Owner

    private let flag: URL
    private let store: AttentionStore
    private let directory: PeerDirectory
    private var started = false
    private var storeFeed: AnyCancellable?
    private var agentFeed: AnyCancellable?
    private let fineFeed = DirectoryWatcher()
    private var fineStamp: Date?
    private var launchObserver: NSObjectProtocol?
    /// 시험에서는 화면 노치(창·전역 마우스 감시)를 띄우지 않는다.
    private let showsNotch: Bool

    init(flag: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".space-manager/notch-owner"),
         store: AttentionStore? = nil, directory: PeerDirectory = .shared, showsNotch: Bool = true) {
        self.flag = flag
        self.store = store ?? .shared
        self.directory = directory
        self.showsNotch = showsNotch
        owner = (try? String(contentsOf: flag, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "sm" ? .sm : .fine
    }

    /// 앱이 뜰 때 한 번.
    func start() {
        guard !started else { return }
        started = true
        if owner == .sm {
            becomeOwner(importing: false)
            return
        }
        followFine()
        probe()
        // Fine이 (새 판으로) 다시 뜨면 그때 묻는다. 소켓이 서기까지 잠깐 걸린다.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == FineControl.bundleID else { return }
            for delay in [2.0, 6.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.probe() }
            }
        }
    }

    /// Fine에게 노치가 아직 있는지 묻는다.
    func probe() {
        guard owner == .fine else { return }
        FineControl.request("attention.status", [:]) { [weak self] reply in
            if reply.isUnknownCommand { self?.becomeOwner(importing: true) }
        }
    }

    /// sm이 노치를 갖는다.
    func becomeOwner(importing: Bool) {
        if owner != .sm {
            owner = .sm
            try? FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "sm\n".write(to: flag, atomically: true, encoding: .utf8)
        }
        if importing { importFromFine() }
        fineFeed.stop()
        fineFeed.onChange = nil
        agentFeed = directory.$agents.receive(on: DispatchQueue.main).sink { [weak self] agents in
            MainActor.assumeIsolated { self?.store.settle(with: agents) }
        }
        storeFeed = store.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
            self?.directory.applyNotch(items)
        }
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if showsNotch { AttentionNotch.shared.start() }
    }

    /// Fine 노치에 떠 있던 것(SEOL이 아직 손대지 않은 것)만 가져온다. 지난 working·unknown 줄은 두고 온다.
    private func importFromFine() {
        guard store.items.isEmpty, let items = FineControl.load() else { return }
        for item in items where item.state.needsAttention {
            var args: [String: Any] = ["host": item.host, "source": item.source, "key": item.key, "title": item.title,
                                       "message": item.message, "fingerprint": item.fingerprint, "state": item.state.rawValue]
            if let workspace = item.workspace { args["workspace"] = workspace }
            _ = try? store.post(args, now: item.updatedAt)
        }
    }

    /// Fine이 노치를 갖는 동안: Fine의 알림 파일을 따라 패널 표시를 맞춘다(Fine은 파일을 통째로 바꿔 끼우므로 폴더를 본다).
    private func followFine() {
        reloadFine()
        fineFeed.onChange = { [weak self] in MainActor.assumeIsolated { self?.reloadFine() } }
        fineFeed.start(path: FineControl.home.path)
    }

    func reloadFine() {
        guard owner == .fine else { return }
        let stamp = (try? FineControl.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard stamp != fineStamp || stamp == nil else { return }
        fineStamp = stamp
        directory.applyNotch(FineControl.load() ?? [])
    }

    // MARK: 입구

    /// `attention.*` 제어 명령. Fine이 노치를 가진 동안은 그대로 넘기고, Fine이 모른다고 하면 이어받아 직접 한다.
    func handle(_ request: ControlRequest, completion: @escaping (ControlResponse) -> Void) {
        guard owner == .fine else { return handleHere(request, completion: completion) }
        FineControl.request(request.command, request.args) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .ok(let result): completion(.ok(result))
            case .failed(let message) where reply.isUnknownCommand:
                _ = message
                self.becomeOwner(importing: true)
                self.handleHere(request, completion: completion)
            case .failed(let message): completion(.error(message))
            case .unreachable: completion(.error("notch is not reachable: Fine owns the notch and is not running"))
            }
        }
    }

    /// 앱 안에서 올리기(패널의 터미널 알림).
    func post(_ fields: [String: String]) {
        handle(ControlRequest(command: "attention.post", args: fields)) { _ in }
    }

    /// 앱 안에서 지우기(패널 이름표의 ×, 탭 칩 메뉴).
    func dismiss(_ id: String) {
        handle(ControlRequest(command: "attention.dismiss", args: ["id": id])) { _ in }
    }

    private func handleHere(_ r: ControlRequest, completion: @escaping (ControlResponse) -> Void) {
        let notch = AttentionNotch.shared
        do {
            switch r.command {
            case "attention.post":
                completion(.ok(try store.post(r.args).json))
            case "attention.list":
                completion(.ok(store.ordered.map(\.json)))
            case "attention.dismiss":
                guard let id = r.string("id") else { throw AttentionError("id required") }
                try store.dismiss(id: id)
                completion(.ok(["dismissed": id]))
            case "attention.show":
                notch.reveal()
                completion(.ok(notch.status))
            case "attention.hide":
                notch.hide()
                completion(.ok(notch.status))
            case "attention.status":
                completion(.ok(notch.status.merging(["owner": "sm"]) { $1 }))
            case "attention.snapshot":
                guard let path = r.string("path"), path.hasPrefix("/") else { throw AttentionError("absolute path required") }
                let compact = r.bool("compact") ?? false
                if !compact { notch.reveal(automatic: true, detail: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    do { try notch.snapshot(to: path, compact: compact); completion(.ok(["path": path])) }
                    catch { completion(.error(String(describing: error))) }
                }
            case "attention.open":
                guard let id = r.string("id"), let item = store.items.first(where: { $0.id == id }) else {
                    throw AttentionError("notification not found")
                }
                Task {
                    do { try await AttentionRouter.open(item); completion(.ok(["opened": id])) }
                    catch { completion(.error(String(describing: error))) }
                }
            default:
                throw AttentionError("unknown command: \(r.command)")
            }
        } catch {
            completion(.error(String(describing: error)))
        }
    }
}

/// Fine 제어 소켓과 Fine의 알림 파일. 노치가 아직 Fine에 있는 동안 넘겨 주는 데, 그리고 Fine 탭을 앞으로
/// 가져오는 데 쓴다. 규약은 JSON 한 줄(tmux-bridge-fine의 rpc와 같다).
enum FineControl {
    static let bundleID = "com.seol.fine"
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".fine") }
    static var file: URL { home.appendingPathComponent("attention.json") }
    static var socket: String { home.appendingPathComponent("control.sock").path }
    static var cli: String { NSHomeDirectory() + "/bin/fine" }

    enum Reply {
        case ok(Any)
        case failed(String)
        case unreachable

        /// 노치를 걷어 낸 Fine의 답.
        var isUnknownCommand: Bool {
            if case .failed(let message) = self { return message.hasPrefix("unknown command") }
            return false
        }
    }

    /// Fine 노치 파일의 항목들(Fine의 AttentionItem Codable 그대로 — sm이 옮겨 온 같은 타입이다).
    static func load(_ file: URL = FineControl.file) -> [AttentionItem]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([AttentionItem].self, from: data)
    }

    /// 그 sm 세션(`NAME` 또는 `NAME@HOST`)을 보고 있는 Fine 탭의 id. Fine의 sm 모드 탭은 `tab.list` 행에
    /// `smSession`(세션 이름, 다른 기기면 `NAME@HOST`)을 단다. Fine이 꺼져 있으면 nil — 띄우지는 않는다.
    static func tab(showing target: String, localHost: String, completion: @escaping @MainActor (String?) -> Void) {
        let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts[0], host = parts.count > 1 ? parts[1] : localHost
        request("tab.list", [:]) { reply in
            guard case .ok(let result) = reply, let rows = result as? [[String: Any]] else { return completion(nil) }
            let row = rows.first { row in
                guard let session = row["smSession"] as? String, !session.isEmpty else { return false }
                let pieces = session.split(separator: "@", maxSplits: 1).map(String.init)
                let rowHost = pieces.count > 1 ? pieces[1] : (row["smHost"] as? String ?? localHost)
                return pieces[0].caseInsensitiveCompare(name) == .orderedSame && rowHost == host
            }
            completion(row?["id"] as? String)
        }
    }

    /// `fine attach NAME[@HOST]`: Fine이 그 sm 세션에 붙은 탭을 연다(필요하면 Fine을 띄운다). 실패하면 그 까닭.
    static func attach(_ target: String, completion: @escaping @MainActor (String?) -> Void) {
        let path = cli
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["attach", target]
            process.standardOutput = output
            process.standardError = output
            var failure: String?
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = text.isEmpty ? "fine attach가 \(process.terminationStatus)로 끝났습니다" : text
                }
            } catch { failure = "fine을 실행하지 못했습니다: \(error.localizedDescription)" }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    private static let queue = DispatchQueue(label: "SpaceManager.FineControl", qos: .userInitiated)

    /// 보내고 답을 메인에서 받는다.
    static func request(_ command: String, _ args: [String: Any], completion: @escaping @MainActor (Reply) -> Void) {
        let path = socket
        let payload = try? JSONSerialization.data(withJSONObject: ["command": command, "args": args])
        queue.async {
            let reply = payload.map { send($0, to: path) } ?? .failed("invalid arguments")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(reply) } }
        }
    }

    private static func send(_ payload: Data, to path: String) -> Reply {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return .unreachable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .unreachable }
        var line = payload
        line.append(UInt8(ascii: "\n"))
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { return .unreachable }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while reply.last != UInt8(ascii: "\n") {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return .unreachable }
        if object["ok"] as? Bool == true { return .ok(object["result"] ?? NSNull()) }
        return .failed(object["error"] as? String ?? "Fine request failed")
    }
}

/// sm 패널 표시가 노치 알림을 읽는 말.
extension AttentionItem {
    /// `seol-notch`가 올린 것 — 에이전트가 스스로 SEOL을 부른 것. 제목이 "할 일 · 어디"다.
    var isCall: Bool { key == "seol-notch" || key.hasPrefix("seol-notch:") }

    /// 이 알림이 그 에이전트의 것인가. 올린 쪽마다 에이전트를 가리키는 칸이 다르다:
    /// 훅은 key가 peer 행 id(`claude:<세션>`)이고, seol-notch는 key 뒤에 그 칸의 표시(`%12`, `fine:<탭>`,
    /// `peer:<이름>`)를, sm 세션이면 source에 `sm:<이름>`을 단다. 맥에서 올린 것은 host가 "local"이다.
    func refers(to agent: PeerAgent, localHost: String) -> Bool {
        guard (host == "local" ? localHost : host) == agent.host else { return false }
        if key == agent.id { return true }
        let mark = key.hasPrefix("seol-notch:") ? String(key.dropFirst("seol-notch:".count)) : ""
        for address in [source, mark] where !address.isEmpty {
            if let name = Self.name(in: address) {
                if name.caseInsensitiveCompare(agent.name) == .orderedSame { return true }
            } else if address.caseInsensitiveCompare(agent.target) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// `sm:<이름>`·`peer:<이름>`의 이름. sm 패널 target(`sm:<패널 UUID>`, `sm:p-…`)도 sm:으로 시작하지만
    /// 그것은 위치라 target과 그대로 견준다 — 이름이면 이름으로, 아니면 위치로.
    private static func name(in address: String) -> String? {
        if address.hasPrefix("peer:") { return String(address.dropFirst(5)) }
        guard address.hasPrefix("sm:") else { return nil }
        let rest = String(address.dropFirst(3))
        if rest.hasPrefix("p-") || UUID(uuidString: rest) != nil { return nil }
        return rest
    }

    /// 패널 이름표에 붙는 짧은 말. 노치 줄의 굵은 글(할 일)과 같은 말을 쓴다.
    var shortLabel: String {
        if state == .error { return "실패" }
        if isCall {
            let action = title.components(separatedBy: " · ").first ?? title
            return action.isEmpty ? "확인" : action
        }
        if message.hasPrefix("권한") { return "권한" }
        if key.hasPrefix("terminal:") { return "알림" }
        return "질문"
    }

    /// 툴팁에 쓰는 노치 본문.
    var detailText: String { message.isEmpty ? title : message }
}
