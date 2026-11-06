import Foundation
import Combine

// 노치의 알림 목록. Fine에서 옮겨 왔다(11/01, SEOL: "노치는 sm으로 일괄"). 모양과 규칙(명시적 상태만 믿고,
// 침묵은 끝남으로 읽지 않는다)은 Fine 때 그대로다 — 보내는 쪽(seol-notch, 훅, Fine 탭)이 같은 명령을 쓴다.

enum AttentionState: String, Codable, CaseIterable {
    case working, waiting, blocked, done, error, unknown

    var needsAttention: Bool { self == .waiting || self == .blocked || self == .error }
    var priority: Int {
        switch self {
        case .error: return 5
        case .blocked: return 4
        case .waiting: return 3
        case .unknown: return 2
        case .working: return 1
        case .done: return 0
        }
    }
    var label: String {
        switch self {
        case .working: return "작업 중"
        case .waiting: return "답변 필요"
        case .blocked: return "도움 필요"
        case .done: return "완료"
        case .error: return "오류"
        case .unknown: return "상태 확인 필요"
        }
    }
}

struct AttentionItem: Codable, Equatable, Identifiable {
    let id: String
    let key: String
    let host: String
    let source: String
    let fingerprint: String
    var title: String
    var message: String
    var state: AttentionState
    var updatedAt: Date
    /// The sender's tmux session. Optional so history written before grouping still loads.
    var workspace: String? = nil

    var address: String { source.isEmpty ? host : "\(host):\(source)" }
    /// The group the notch shows this under: a tmux session, Fine itself, or the host.
    var group: String {
        if let workspace, !workspace.isEmpty { return workspace }
        return source.hasPrefix("fine:") ? "Fine" : host
    }
    var json: [String: Any] {
        ["id": id, "key": key, "host": host, "source": source,
         "fingerprint": fingerprint, "title": title, "message": message,
         "state": state.rawValue, "updatedAt": Self.timestamp.string(from: updatedAt),
         "workspace": workspace ?? ""]
    }
    /// 목록을 내줄 때마다 항목마다 새로 만들면 attention.list 한 번에 수십 개다(11/02 프로파일).
    nonisolated(unsafe) private static let timestamp = ISO8601DateFormatter()
    /// A pane's own terminal notification ("Claude is waiting for your input"): a ping, not a question someone asked.
    var isTerminalPing: Bool {
        key.hasPrefix("terminal:") || key.range(of: "^(claude|codex):[0-9a-f][0-9a-f-]{7,}$", options: .regularExpression) != nil
    }
    /// An agent going idle — the pane's terminal notice or a hook's end-of-turn notice — rather than someone asking
    /// SEOL something. Agents talk to each other through peer, so most idle moments need nobody; the pane title
    /// still shows them ("알림"), but the notch pops only for questions (seol-notch, sm notify) and errors (11/06 SEOL
    /// "쓰잘데기없는거만 호출").
    /// A Fine tab is a conversation SEOL is having, so its "waiting" does mean SEOL's turn — those still notify.
    var isPing: Bool {
        !source.hasPrefix("fine:") && isTerminalPing
    }
    /// The sm session it came from (`sm:NAME`), if any.
    var smSession: String? { source.hasPrefix("sm:") ? String(source.dropFirst(3)) : nil }
    /// Hook keys name one harness conversation, which lives in exactly one terminal.
    var isSessionKey: Bool {
        key.range(of: "^[a-z][a-z0-9-]*:[0-9a-f][0-9a-f-]{7,}$", options: .regularExpression) != nil
    }
}

struct AttentionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Explicit events are authoritative. Silence is never interpreted as completion
/// or a question: old working events become unknown until their producer reports again.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore(file: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".space-manager/attention.json"))
    @Published private(set) var items: [AttentionItem] = []
    var onAttention: (() -> Void)?
    private let file: URL?
    private var expiry: Timer?
    static let capacity = 200
    static let workingLease: TimeInterval = 3600
    static let doneLifetime: TimeInterval = 30
    /// 패널의 터미널 알림은 에이전트가 쉴 때마다 오는 신호라, 아무도 그 칸에 치지 않으면 영영 남았다(11/02 노치에
    /// 89개, 최고 21일). 질문(seol-notch·sm notify)과 달리 반나절이 지나면 걷는다.
    static let pingLifetime: TimeInterval = 12 * 3600
    /// A question nobody answered in 3 days is not going to be (11/06: Dori decision cards up to 3 weeks old, seol-notch
    /// questions from long-ended sessions). The decision box (harness-inbox) keeps the originals.
    static let questionLifetime: TimeInterval = 3 * 86400
    /// 같은 알림이 이 안에 다시 오면 파일을 다시 쓰지 않는다(에이전트는 쉴 때마다 같은 알림을 낸다).
    static let repeatWindow: TimeInterval = 60

    init(file: URL? = nil) {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { items = try JSONDecoder().decode([AttentionItem].self, from: Data(contentsOf: file)) }
            catch { NSLog("sm attention history could not be loaded: %@", String(describing: error)) }
        }
    }

    /// What the notch shows: everything but idle pings (those stay for the pane titles, PeerDirectory.notices).
    var shown: [AttentionItem] { items.filter { !$0.isPing } }

    var ordered: [AttentionItem] {
        shown.sorted { a, b in
            if a.state.priority != b.state.priority { return a.state.priority > b.state.priority }
            return a.updatedAt > b.updatedAt
        }
    }
    var waitingCount: Int { shown.filter { $0.state.needsAttention }.count }
    var workingCount: Int { shown.filter { $0.state == .working }.count }

    @discardableResult
    func post(_ args: [String: Any], now: Date = Date()) throws -> AttentionItem {
        func field(_ name: String, default fallback: String = "", max: Int) throws -> String {
            if let value = args[name], !(value is String) { throw AttentionError("\(name) must be a string") }
            let value = (args[name] as? String ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= max, !value.contains("\0") else { throw AttentionError("invalid or oversized \(name)") }
            return value
        }
        let host = try field("host", default: "local", max: 100)
        let source = try field("source", max: 100)
        let key = try field("key", default: UUID().uuidString.lowercased(), max: 160)
        let title = try field("title", default: "에이전트", max: 300)
        let message = try field("message", max: 8000)
        let fingerprint = try field("fingerprint", max: 120)
        let workspace = try field("workspace", max: 100)
        guard host.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
              !key.isEmpty, !title.isEmpty else { throw AttentionError("host, key and title are required") }
        // sm:NAME is an sm session (no tmux pane or Fine tab); AttentionRouter opens it with `sm reveal`.
        guard source.isEmpty || source.range(of: "^(%[0-9]+|[a-z0-9]{4}|fine:[a-fA-F0-9-]{36}|sm:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63})$", options: .regularExpression) != nil else {
            throw AttentionError("source must be a Fine UUID, tmux pane, stable key or sm:NAME")
        }
        if source.hasPrefix("fine:"), UUID(uuidString: String(source.dropFirst(5))) == nil {
            throw AttentionError("invalid Fine tab UUID")
        }
        guard let state = AttentionState(rawValue: try field("state", default: "waiting", max: 20)) else {
            throw AttentionError("state must be working|waiting|blocked|done|error|unknown")
        }
        // JSON encoding avoids collisions when keys contain separators.
        let identity = try JSONEncoder().encode([host, source.lowercased(), key]).base64EncodedString()
        let item = AttentionItem(id: identity, key: key, host: host, source: source.lowercased(),
                                 fingerprint: fingerprint, title: title, message: message, state: state, updatedAt: now,
                                 workspace: workspace.isEmpty ? nil : workspace)
        // A resumed conversation reports from its new tab or pane; the old address is gone.
        let moved = { (other: AttentionItem) in
            item.isSessionKey && other.host == item.host && other.key == item.key && other.id != identity
        }
        let old = items.first { $0.id == identity } ?? items.first(where: moved)
        if let old, old.id == identity, old.state == state, old.message == message, old.title == title,
           old.workspace == item.workspace, now.timeIntervalSince(old.updatedAt) < Self.repeatWindow {
            return old
        }
        var next = items.filter { $0.id != identity && !moved($0) }
        guard next.count < Self.capacity else { throw AttentionError("notification queue is full; dismiss an existing item") }
        next.append(item)
        try commit(next)
        let changed = old?.state != state || old?.message != message || old?.title != title
        if state.needsAttention && changed && !item.isPing { onAttention?() }
        scheduleExpiry(now: now)
        return item
    }

    func dismiss(id: String) throws {
        guard items.contains(where: { $0.id == id }) else { throw AttentionError("notification not found") }
        try commit(items.filter { $0.id != id })
        scheduleExpiry()
    }

    func expire(now: Date = Date()) throws {
        let next = items.compactMap { original -> AttentionItem? in
            var item = original
            let age = now.timeIntervalSince(item.updatedAt)
            if item.state == .done && age >= Self.doneLifetime { return nil }
            if item.isTerminalPing && age >= Self.pingLifetime { return nil }
            if item.state.needsAttention && age >= Self.questionLifetime { return nil }
            if item.state == .working && age >= Self.workingLease { item.state = .unknown }
            return item
        }
        if next != items { try commit(next) }
        scheduleExpiry(now: now)
    }

    func start() {
        // 11/02까지 sm 패널의 알림 키는 앱 안 객체의 UUID라, 앱을 다시 켤 때마다 같은 에이전트의 알림이 새로 쌓이고
        // 옛것은 아무도 내리지 못했다. 지금 키는 terminal:NAME@HOST다 — 옛 꼴은 한 번 걷는다.
        let orphan = "^terminal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let kept = items.filter { !($0.smSession != nil && $0.key.range(of: orphan, options: .regularExpression) != nil) }
        do {
            if kept != items { try commit(kept) }
            try expire()
        } catch { NSLog("sm attention expiry failed: %@", String(describing: error)) }
    }

    /// 에이전트가 다시 일하거나 끝났으면, 그 패널의 쉼 알림(터미널 알림, 훅의 세션 알림)은 더 기다리는 게 아니다. peer가 알려 주는 상태만 믿는다
    /// (조용함을 끝남으로 읽지 않는다): 알림 뒤에 working이 됐거나, gone이다. 질문 알림은 건드리지 않는다.
    func settle(with agents: [PeerAgent], now: Date = Date()) {
        var changed = false
        let next = items.compactMap { original -> AttentionItem? in
            guard original.isTerminalPing || original.isSessionKey, original.state.needsAttention, let name = original.smSession,
                  let agent = agents.first(where: { $0.name == name && $0.host == original.host && !$0.isStale }) else { return original }
            if agent.state == .gone { changed = true; return nil }
            if agent.state == .working && agent.since > original.updatedAt {
                var item = original
                item.state = .done
                item.message = "이어서 진행하고 있어요."
                item.updatedAt = now
                changed = true
                return item
            }
            return original
        }
        guard changed else { return }
        do { try commit(next); scheduleExpiry(now: now) } catch { NSLog("sm attention settle failed: %@", String(describing: error)) }
    }

    private func commit(_ next: [AttentionItem]) throws {
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(next)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        items = next
    }

    private func scheduleExpiry(now: Date = Date()) {
        expiry?.invalidate(); expiry = nil
        let deadline = items.compactMap { item -> Date? in
            switch item.state {
            case .working: return item.updatedAt.addingTimeInterval(Self.workingLease)
            case .done: return item.updatedAt.addingTimeInterval(Self.doneLifetime)
            default:
                if item.isTerminalPing { return item.updatedAt.addingTimeInterval(Self.pingLifetime) }
                return item.state.needsAttention ? item.updatedAt.addingTimeInterval(Self.questionLifetime) : nil
            }
        }.min()
        guard let deadline else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: max(0.1, deadline.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                do { try self?.expire() } catch { NSLog("sm attention expiry failed: %@", String(describing: error)) }
            }
        }
        expiry?.tolerance = 1
    }
}
