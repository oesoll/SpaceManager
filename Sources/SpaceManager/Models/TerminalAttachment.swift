import Foundation

/// 패널에 터미널을 붙이는 방법 — 이 파일 하나에 모은다. 화면(패널·카드·상태)은 이것을 모른다.
///
/// 세션을 띄우고 살려 두고 붙고 되살리는 일은 sm의 세션 층(`sm-session`, 모든 기기에서 도는 CLI)이
/// 맡는다 — tmux가 하던 일이다(10/31 SEOL·cld-claude-7). 이 앱은 화면 층이라, 패널은
/// `sm-session attach NAME@HOST` 한 줄을 실행할 뿐이다. 로컬이면 그 기기의 holder에, 원격이면
/// `ssh -t`로 그 기기의 sm-session에 붙는 것은 세션 층이 고른다. 그래서 이 파일은 기기마다 다른
/// 소켓 경로·ssh 규칙을 모른다. 패널을 닫거나 앱을 다시 띄워도 에이전트는 계속 돈다.
/// (CLI에서는 `sm attach …`가 같은 명령이다. 앱은 PATH의 sm 버전과 무관하게 세션 층을 바로 부른다.)
/// 2단계: 기기마다 ssh 하나로 holder와 패널별 메시지를 직접 주고받는다(보이는 패널만 화면을 받고,
/// 크기 변경도 메시지다). 그때는 이 파일과 터미널 표면의 입출력만 바꾼다.
enum TerminalAttachment: Equatable {
    /// 워크스페이스 폴더의 로그인 셸. 원격이면 그 호스트의 셸.
    case shell
    /// 세션 층이 아는 에이전트(이름@기기)의 터미널. 이름이 곧 세션이다. `agent`는 상태를 잇는 peer 행 id.
    case agent(name: String, host: String, agent: String?)

    /// 로그인 셸이 실행할 명령. nil이면 셸 그대로.
    func command() -> String? {
        switch self {
        case .shell:
            return nil
        case .agent(let name, let host, _):
            return "exec sm-session attach " + Self.quote(name + "@" + host)
        }
    }

    /// POSIX 셸 작은따옴표 인용.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
