import Foundation

/// 패널에 터미널을 붙이는 방법 — 이 파일 하나에 모은다. 화면(패널·카드·상태)은 이것을 모른다.
///
/// 1단계(10/31 cld-claude-7과 확정, `~/cld/smux-wt/hold/hold/PROTOCOL.md`): 에이전트의 PTY는
/// 기기의 `peer-hold`가 쥐고, 패널의 PTY는 `peer-hold attach --sock <소켓>` 한 줄을 실행한다.
/// 원격이면 `ssh -t <host>` 뒤에서 같은 명령을 실행한다. 패널을 닫거나 앱을 다시 띄워도 에이전트는 계속 돈다.
/// 2단계: sm이 기기마다 ssh 하나(`peer-hold mux`)를 열고 holder와 패널별 메시지를 직접 주고받는다
/// (보이는 패널만 화면을 받고, 크기 변경도 메시지다). 그때는 이 파일과 `TerminalSession`의
/// PTY 연결부만 바꾼다.
enum TerminalAttachment: Equatable {
    /// 워크스페이스 폴더의 로그인 셸. 원격이면 그 호스트의 셸.
    case shell
    /// holder가 쥔 에이전트 터미널. `host`는 peer 기기 이름(mac, arch), `agent`는 상태를 잇는 peer 행 id.
    case hold(socket: String, host: String, agent: String?)

    /// 로그인 셸이 실행할 명령. nil이면 셸 그대로.
    /// - Parameter sshAlias: peer 기기 이름(nuc)을 ssh 별칭(nuc-pet)으로.
    func command(localHost: String, sshAlias: (String) -> String?) -> String? {
        switch self {
        case .shell:
            return nil
        case .hold(let socket, let host, _):
            let attach = "peer-hold attach --sock " + Self.quote(socket)
            guard host != localHost else { return "exec " + attach }
            let alias = sshAlias(host) ?? host
            // 원격 명령은 비로그인 셸에서 돈다. peer-hold가 있는 PATH를 얻으려고 로그인 셸로 감싼다.
            return "exec ssh -t " + Self.quote(alias) + " " + Self.quote("exec $SHELL -lc " + Self.quote(attach))
        }
    }

    /// POSIX 셸 작은따옴표 인용.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension PeerDirectory {
    /// peer 기기 이름 → ssh 별칭(`~/.smux/hosts`의 `이름 = 별칭`). `peerHost(forAlias:)`의 반대.
    func sshAlias(forPeerHost host: String) -> String? {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.smux/hosts", encoding: .utf8)) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == host, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
}
