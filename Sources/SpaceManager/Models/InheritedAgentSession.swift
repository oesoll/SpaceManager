import Foundation

/// sm을 에이전트 셸에서 띄웠을 때(설치·재시작) 그 셸의 세션 정체를 앱 환경에서 지운다. Fine과 같은 처방이다.
///
/// `open`도 부른 셸의 환경을 앱에 넘긴다. 2026-10-31 sm-front가 설치 뒤 sm을 다시 띄우자 앱 환경에
/// `CLAUDECODE`·`CLAUDE_CODE_CHILD_SESSION`·그 세션의 메시지 소켓과 토큰·`PEER_NAME`이 들어갔고, 로컬 패널의
/// attach 클라이언트가 그것을 물려받았다(sm-ghostty 확인). 새 Quick 탭의 Claude는 대화 기록을 끄고
/// ("Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION"), peer에서는 남의 이름으로 보인다.
///
/// 앱이 시작하자마자 지우므로 패널·Quick 탭·세션 층 명령 등 sm이 띄우는 모든 자식이 깨끗하다. `SM_PANE_ID`와
/// `SM_WORKSPACE`는 sm이 패널마다 다시 넣는다. Finder로 띄운 sm에는 이 변수들이 처음부터 없다.
enum InheritedAgentSession {
    /// 세션 하나에만 속하는 변수. `CODEX_HOME`처럼 사용자 설정인 것은 건드리지 않는다.
    static func isSessionVariable(_ name: String) -> Bool {
        if ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT", "SM_PANE_ID", "SM_WORKSPACE",
            "CODEX_THREAD_ID"].contains(name) { return true }
        return name.hasPrefix("CLAUDE_CODE_") || name.hasPrefix("PEER_") || name.hasPrefix("CODEX_SANDBOX")
    }

    static func sessionVariables(in environment: [String: String]) -> [String] {
        environment.keys.filter(isSessionVariable).sorted()
    }

    /// 이 프로세스 환경에서 지운다. 무엇을 지웠는지 돌려준다(진단용).
    /// unsetenv는 다른 스레드가 환경을 읽는 동안 부르면 안전하지 않다 — 앱 시작(자식을 띄우기 전)에만 부른다.
    @discardableResult
    static func clear(environment: [String: String] = ProcessInfo.processInfo.environment,
                      unset: (String) -> Void = { unsetenv($0) }) -> [String] {
        let names = sessionVariables(in: environment)
        names.forEach(unset)
        return names
    }
}
