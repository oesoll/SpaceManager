import Foundation

/// Fine 노치의 알림 하나 — Fine이 `~/.fine/attention.json`에 쓰는 항목(Fine의 AttentionItem)에서 sm이 쓰는 칸만.
///
/// 노치가 "SEOL이 손대야 하는 것"의 원본이다(11/01 SEOL: "노치알림을 fine, sm에 완벽 동기화"). sm은 그 목록을
/// 그대로 읽어 같은 에이전트의 패널·탭·워크스페이스에 표시하고, 지우기는 Fine에 맡긴다. 그래서 두 앱이 같은
/// 것을 보이고, 한쪽에서 지우면 다른 쪽에서도 사라진다.
struct NotchNotice: Decodable, Equatable, Identifiable {
    let id: String
    let key: String
    let host: String
    let source: String
    let title: String
    let message: String
    let state: String
    let updatedAt: Date

    /// 노치가 눈에 띄게 올리는 상태(Fine AttentionState.needsAttention과 같다).
    var needsSEOL: Bool { state == "waiting" || state == "blocked" || state == "error" }

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
                if name == agent.name { return true }
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
        if state == "error" { return "실패" }
        if isCall {
            let action = title.components(separatedBy: " · ").first ?? title
            return action.isEmpty ? "확인" : action
        }
        if message.hasPrefix("권한") { return "권한" }
        if key.hasPrefix("terminal:") { return "알림" }
        return "질문"
    }

    /// 툴팁에 쓰는 노치 본문(두 줄 안팎).
    var detailText: String { message.isEmpty ? title : message }
}

/// Fine 노치와 주고받는 길. 읽기는 Fine의 파일, 쓰기(지우기·올리기)는 Fine의 제어 소켓이다 — 같은 기기의
/// 같은 사용자라 둘 다 가깝고, 소켓은 Fine이 떠 있어야만 받는다(안 떠 있으면 노치도 없다).
///
/// 파일 모양은 Fine의 AttentionItem Codable(날짜는 기본 인코딩) 그대로다. Fine이 저장 모양을 바꾸면
/// 여기 디코딩도 같이 바꾼다 — 그럴 일이 잦아지면 Fine에 `attention.list` 구독을 두고 그쪽으로 옮긴다.
enum FineNotch {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".fine") }
    static var file: URL { home.appendingPathComponent("attention.json") }
    static var socket: String { home.appendingPathComponent("control.sock").path }

    static func load(_ file: URL = FineNotch.file) -> [NotchNotice]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([NotchNotice].self, from: data)
    }

    /// 노치에서 지운다(노치의 ×와 같다).
    static func dismiss(_ id: String) {
        call("attention.dismiss", ["id": id])
    }

    /// 노치에 올리거나 같은 key의 항목을 바꾼다. 실패해도 조용하다 — 노치는 알림 길이지 작업 길이 아니다.
    static func post(_ fields: [String: String], completion: ((Bool) -> Void)? = nil) {
        call("attention.post", fields, completion: completion)
    }

    private static let queue = DispatchQueue(label: "SpaceManager.FineNotch", qos: .userInitiated)

    /// JSON 한 줄을 보내고 한 줄을 받는다(Fine 제어 소켓 규약, tmux-bridge-fine의 rpc와 같다).
    static func call(_ command: String, _ args: [String: Any], completion: ((Bool) -> Void)? = nil) {
        let path = socket
        queue.async {
            let ok = send(command, args, to: path)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    private static func send(_ command: String, _ args: [String: Any], to path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0,
              var payload = try? JSONSerialization.data(withJSONObject: ["command": command, "args": args]) else { return false }
        payload.append(UInt8(ascii: "\n"))
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { return false }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.last != UInt8(ascii: "\n") {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return false }
        return object["ok"] as? Bool == true
    }
}
