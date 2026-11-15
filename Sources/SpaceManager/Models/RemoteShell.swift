import Foundation

/// 원격 워크스페이스의 셸 패널(세션 없는 패널): 그 기기의 작업 폴더에서 로그인 셸을 ssh로 띄운다.
/// 에이전트 패널은 세션 층(`sm-session attach NAME@HOST`)이 기기를 고르므로 여기를 거치지 않는다.
enum RemoteShell {
    /// 원격 작업 디렉토리. 로컬 홈 아래 경로는 원격 `$HOME` 기준으로 옮긴다 — 두 머신의
    /// 홈 경로가 다르므로(/Users vs /home) 절대경로를 그대로 보내면 없는 디렉토리가 된다.
    enum Directory: Equatable {
        case relativeToHome(String)
        case absolute(String)

        /// 원격 셸이 해석할 표현식. 홈 상대경로는 `"$HOME/"'rel'`로 만들어 `$HOME`만 확장되고
        /// 나머지는 인용된 채 남는다.
        var shellExpression: String {
            switch self {
            case .relativeToHome(let rel): return "\"$HOME/\"" + rel.shQuoted
            case .absolute(let abs): return abs.shQuoted
            }
        }
    }

    static func directory(forLocalPath path: String, localHome: String = NSHomeDirectory()) -> Directory {
        let home = localHome.hasSuffix("/") ? String(localHome.dropLast()) : localHome
        if path == home { return .relativeToHome("") }
        if path.hasPrefix(home + "/") {
            return .relativeToHome(String(path.dropFirst(home.count + 1)))
        }
        return .absolute(path)
    }

    /// 로컬 셸이 실행할 한 줄: `ssh -t host 'bash -lc <script>'`. keepalive로 슬립/네트워크 전환 시
    /// 죽은 연결을 빨리 정리한다.
    static func launchCommand(host: String, remoteScript: String) -> String {
        let remoteCommand = "bash -lc " + remoteScript.shQuoted
        return "exec ssh -t -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "
            + host.shQuoted + " -- " + remoteCommand.shQuoted
    }

    /// 원격 디렉토리에서 로그인 셸.
    static func shellCommand(host: String, directory: Directory) -> String {
        let script = "cd " + directory.shellExpression + " 2>/dev/null; exec \"${SHELL:-bash}\" -l"
        return launchCommand(host: host, remoteScript: script)
    }
}

extension String {
    /// POSIX 셸 작은따옴표 인용.
    var shQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
