import Foundation

/// peer가 보고하는 에이전트의 상태. 계약(10/31 cld-claude-7)상 값은 이 일곱이 전부다.
/// 모르는 값이 와도 목록 전체를 버리지 않도록 unknown으로 읽는다.
enum PeerState: String, Decodable, Equatable {
    case working, blocked, idle, error, gone, unknown
    case waitingOn = "waiting-on"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeerState(rawValue: raw) ?? .unknown
    }
}

/// `peer --all --json`의 행 하나 — 에이전트 하나와 그 터미널의 위치(target).
/// 화면은 target만 보고 패널에 잇는다. 그 아래가 tmux(`%12`)인지 Fine(`fine:<UUID>`)인지
/// sm 패널(`sm:<UUID>`)인지는 매칭하는 쪽이 고른다.
struct PeerAgent: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let host: String
    let cwd: String?
    let title: String?
    let target: String
    let state: PeerState
    let reason: String?
    let since: Date
    /// tmux 행에만 있는 위치. sm이 배치의 원본이 되면 쓰지 않는다.
    let group: String?
    let window: Int?
    let pane: Int?
    let waitingOn: String?
    /// 마지막으로 성공한 목록에 없던 원격 행. 연결이 끊긴 동안 지난 상태를 흐리게 보여 준다.
    var isStale = false

    /// 세션 id는 기기를 넘어 겹치지 않지만, 같은 세션이 두 기기에서 보고되는 일을 막지는 못한다.
    var key: String { host + "/" + id }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, cwd, title, target, state, reason, since, group, window, pane
        case waitingOn = "waiting_on"
    }

    init(id: String, name: String, kind: String = "claude", host: String, cwd: String? = nil,
         title: String? = nil, target: String, state: PeerState, reason: String? = nil,
         since: Date, group: String? = nil, window: Int? = nil, pane: Int? = nil,
         waitingOn: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.cwd = cwd
        self.title = title; self.target = target; self.state = state; self.reason = reason
        self.since = since; self.group = group; self.window = window; self.pane = pane
        self.waitingOn = waitingOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "claude"
        host = try c.decode(String.self, forKey: .host)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        state = try c.decodeIfPresent(PeerState.self, forKey: .state) ?? .unknown
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        since = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .since) ?? 0)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        window = try c.decodeIfPresent(Int.self, forKey: .window)
        pane = try c.decodeIfPresent(Int.self, forKey: .pane)
        waitingOn = try c.decodeIfPresent(String.self, forKey: .waitingOn)
    }
}

/// 사이드바에 그리는 상태. SEOL이 손대야 하는 것(막힘·오류)은 Fine 노치와 같은 것이고, 나머지는 peer 상태다.
///
/// 예전에는 "턴이 끝났는데 SEOL이 아직 안 본" 에이전트를 sm이 따로 done으로 올렸다. 노치에는 없는 추측이라
/// 두 앱이 어긋났고, 턴이 끝난 것이 다른 에이전트의 답을 기다리는 것일 수도 있다(SEOL 10/30). 정말 SEOL이
/// 필요한지는 에이전트가 `seol-notch`로 말하고, 그것이 노치와 sm에 같이 뜬다(11/01 SEOL: "완벽 동기화").
enum AgentAttention: Int, Comparable {
    case gone, unknown, idle, waiting, working, error, blocked

    /// 클수록 급하다. 워크스페이스 줄에는 안의 패널 중 가장 급한 것 하나가 올라간다.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// SEOL이 손대야 하는 상태. 다음 패널로 건너뛰기(⌘J)가 도는 대상이다.
    var needsSEOL: Bool { self == .blocked || self == .error }

    /// peer 상태만으로. 노치가 있으면 PeerDirectory.attention(of:)이 그것을 먼저 본다.
    static func of(_ agent: PeerAgent) -> AgentAttention {
        switch agent.state {
        case .blocked: return .blocked
        case .error: return .error
        case .working: return .working
        case .waitingOn: return .waiting
        case .gone: return .gone
        case .unknown: return .unknown
        case .idle: return .idle
        }
    }
}

/// peer의 목록 결과. 원격 실패는 문자열로만 온다.
struct PeerListing: Decodable {
    let peers: [PeerAgent]
    let unreachable: [String]

    enum CodingKeys: String, CodingKey { case peers, unreachable }

    init(peers: [PeerAgent], unreachable: [String] = []) {
        self.peers = peers
        self.unreachable = unreachable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peers = try c.decode([PeerAgent].self, forKey: .peers)
        unreachable = (try? c.decodeIfPresent([String].self, forKey: .unreachable)) ?? []
    }

    static func decode(_ data: Data) throws -> PeerListing {
        try JSONDecoder().decode(PeerListing.self, from: data)
    }
}

/// 맥·아치·누크의 에이전트 목록. `peer --all --json`을 창이 보일 때만 2초마다 읽는다(한 번 0.2초 안팎).
/// 모든 창이 같은 목록을 보므로 하나만 돈다.
///
/// 폴링이다 — blocked가 최대 2초 늦게 뜬다. peer에 변화 스트림이 생기면 `refresh` 호출부만 바꾼다.
final class PeerDirectory: ObservableObject {
    static let shared = PeerDirectory()

    @Published private(set) var agents: [PeerAgent] = []
    @Published private(set) var unreachable: [String] = []
    /// Fine 노치의 알림 중 SEOL이 손댈 것. 노치 파일이 바뀌면 바로 따라온다.
    @Published private(set) var notices: [NotchNotice] = []

    static let interval: TimeInterval = 2

    private let command: [String]
    private let localHost: String
    private let visibilityID = UUID()
    private var owners = Set<UUID>()
    private var timer: Timer?
    private var inFlight = false
    private let notchFile: URL?
    /// Fine은 알림 파일을 통째로 바꿔 끼우므로(atomic write) 파일이 아니라 그 폴더를 지켜본다.
    private let notchWatcher = DirectoryWatcher()
    private var notchStamp: Date?
    /// peer가 막힘·오류라고 하는 동안(그 상태가 된 시각까지가 한 번) 노치에 그 알림이 있었던 것, 그리고 있다가
    /// 사라진 것. 노치에서 지웠으면 sm에서도 내린다 — 에이전트가 아직 그 상태여도. 노치에 한 번도 오지 않은
    /// 것(맥이 잠든 사이 배달이 빠진 아치 알림 등)은 peer 상태대로 보인다.
    private var noticedEpisodes = Set<String>()
    private var dismissedEpisodes = Set<String>()
    private let queue = DispatchQueue(label: "SpaceManager.PeerDirectory", qos: .utility)

    init(command: [String] = PeerDirectory.defaultCommand, localHost: String = PeerDirectory.readLocalHost(),
         notchFile: URL? = FineNotch.file) {
        self.command = command
        self.localHost = localHost
        self.notchFile = notchFile
        reloadNotch()
        if let notchFile {
            notchWatcher.onChange = { [weak self] in self?.reloadNotch() }
            notchWatcher.start(path: notchFile.deletingLastPathComponent().path)
        }
    }

    static var defaultCommand: [String] {
        [NSHomeDirectory() + "/.smux/bin/peer", "--all", "--json"]
    }

    /// peer가 자기 기기를 부르는 이름. 실행 위치 "mac"과 같은 이름이어야 로컬 행을 가른다.
    static func readLocalHost() -> String {
        let file = NSHomeDirectory() + "/.smux/hostname"
        let name = (try? String(contentsOfFile: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil)
            ?? (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac")
    }

    var isLocalHost: (String) -> Bool { { [localHost] in $0 == localHost } }
    var localHostName: String { localHost }

    /// 워크스페이스의 실행 위치는 ssh 별칭(arch, nuc-pet)이고 peer는 기기 이름(arch, nuc)으로 부른다.
    /// `~/.smux/hosts`의 `이름 = 별칭` 줄로 되짚고, 없으면 별칭을 그대로 이름으로 본다.
    func peerHost(forAlias alias: String) -> String {
        hostAliases[alias] ?? alias
    }

    private lazy var hostAliases: [String: String] = {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.smux/hosts", encoding: .utf8)) ?? ""
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { map[parts[1]] = parts[0] }
        }
        return map
    }()

    func start(owner: UUID) {
        let first = owners.isEmpty
        owners.insert(owner)
        guard first else { return }
        AppResourcePolicy.shared.observe(visibilityID) { [weak self] in self?.setVisible($0) }
    }

    func stop(owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        AppResourcePolicy.shared.removeObserver(visibilityID)
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.5
    }

    func refresh() {
        // 노치 폴더를 지켜보지 못하는 경우(앱이 Fine보다 먼저 떠 ~/.fine이 없었다)를 위한 2초 확인.
        if !notchWatcher.isWatching { reloadNotch() }
        guard !inFlight else { return }
        inFlight = true
        let command = command
        queue.async { [weak self] in
            let listing = Self.run(command)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if let listing { self.apply(listing) }
            }
        }
    }

    /// 새 목록을 받아 게시한다. 원격 하나가 응답하지 않으면 그 기기의 지난 행을 흐리게 남긴다.
    /// 오류 문자열에는 기기 이름이 없으므로, 실패가 있는 동안 사라진 원격 기기 전체를 끊긴 것으로 본다.
    func apply(_ listing: PeerListing, now: Date = Date()) {
        var rows = listing.peers
        if !listing.unreachable.isEmpty {
            let present = Set(rows.map(\.host))
            let kept = agents.filter { !isLocalHost($0.host) && !present.contains($0.host) }
                .map { row -> PeerAgent in var row = row; row.isStale = true; return row }
            rows += kept
        }
        if rows != agents { agents = rows }
        if listing.unreachable != unreachable { unreachable = listing.unreachable }
        reconcileEpisodes()
    }

    /// 노치 파일을 다시 읽는다(바뀌었을 때만). 파일이 없으면 노치에 아무것도 없는 것이다.
    func reloadNotch() {
        guard let notchFile else { return }
        let stamp = (try? notchFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard stamp != notchStamp || stamp == nil else { return }
        notchStamp = stamp
        applyNotch(FineNotch.load(notchFile) ?? [])
    }

    func applyNotch(_ items: [NotchNotice]) {
        let next = items.filter(\.needsSEOL)
        if next != notices { notices = next }
        reconcileEpisodes()
    }

    /// 이 에이전트를 가리키는 노치 알림(여럿이면 가장 최근 것).
    func notice(for agent: PeerAgent) -> NotchNotice? {
        notices.filter { $0.refers(to: agent, localHost: localHost) }.max { $0.updatedAt < $1.updatedAt }
    }

    /// 에이전트가 없는 패널(셸, Quick)이 올린 터미널 알림(TerminalSession.terminalNoticeKey).
    func terminalNotice(for session: TerminalSession) -> NotchNotice? {
        notices.first { $0.key == session.terminalNoticeKey }
    }

    func attention(of agent: PeerAgent) -> AgentAttention {
        if let notice = notice(for: agent) { return notice.state == "error" ? .error : .blocked }
        let own = AgentAttention.of(agent)
        if own.needsSEOL, dismissedEpisodes.contains(Self.episode(agent)) { return .idle }
        return own
    }

    private static func episode(_ agent: PeerAgent) -> String { agent.key + "@" + String(agent.since.timeIntervalSince1970) }

    private func reconcileEpisodes() {
        var live = Set<String>()
        for agent in agents where AgentAttention.of(agent).needsSEOL {
            let episode = Self.episode(agent)
            live.insert(episode)
            if notice(for: agent) != nil {
                noticedEpisodes.insert(episode)
            } else if noticedEpisodes.contains(episode), !dismissedEpisodes.contains(episode) {
                dismissedEpisodes.insert(episode)
                objectWillChange.send()
            }
        }
        noticedEpisodes.formIntersection(live)
        dismissedEpisodes.formIntersection(live)
    }

    private static func run(_ command: [String]) -> PeerListing? {
        guard let executable = command.first, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // Finder에서 뜬 앱의 PATH에는 ~/.smux/bin과 Homebrew가 없다. peer는 ssh·tmux를 이름으로 부른다.
        let extra = [NSHomeDirectory() + "/.smux/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? PeerListing.decode(data)
    }
}
