import SwiftUI
import AppKit

/// 에이전트 상태 표시. 색만이 아니라 모양으로도 갈린다 — 곁눈으로 봐도 구분되고,
/// 사이드바의 "최근 대화" 분홍 점(진하기로 최근성을 말한다)과도 겹치지 않는다.
///
/// - SEOL 차례(노치에 뜬 것: 권한·질문·에이전트가 부른 것): 분홍 느낌표 원
/// - 오류·턴 실패: 호박색 삼각형
/// - 일하는 중: 분홍 회전 링(렌더 서버에서 돈다)
/// - 쉼·다른 에이전트 대기·모름: 표시 없음. 대부분이 여기라 위의 셋이 보인다.
struct AgentStateMark: View {
    let attention: AgentAttention?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 상태가 바뀌면 새 표시가 제자리에서 살짝 커지며 나타난다 — 곁눈으로도 "방금 바뀌었다"가 보이게.
    /// 튀지 않는다. 동작 줄이기에서는 겹쳐 바뀌기만 한다.
    private var change: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.55).combined(with: .opacity)
    }

    var body: some View {
        ZStack {
            switch attention {
            case .blocked:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(Chrome.accent))
                    .transition(change)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.reconnectAmber)
                    .transition(change)
            case .working:
                StateSpinner().frame(width: 11, height: 11)
                    .transition(change)
            default:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: attention)
        .frame(width: 14, height: 14)
        .accessibilityLabel(attention.map(AgentStateMark.spokenName) ?? "")
    }

    static func spokenName(_ attention: AgentAttention) -> String {
        switch attention {
        case .blocked: "SEOL 차례"
        case .error: "오류"
        case .working: "일하는 중"
        case .waiting: "다른 에이전트를 기다림"
        case .idle: "쉬는 중"
        case .gone: "종료됨"
        case .unknown: "상태 모름"
        }
    }
}

/// 사이드바 스피너(`ActivitySpinnerView`)를 그대로 쓴다 — 회전을 CA에 넘겨 메인 스레드가 깨지 않는다.
private struct StateSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivitySpinnerView { ActivitySpinnerView() }
    func updateNSView(_ nsView: ActivitySpinnerView, context: Context) {}
}

/// 패널 이름 줄과 툴팁에 쓰는 글. peer 행이 없으면(셸 패널) 이름만 남는다.
struct PaneBadge: Equatable {
    var title: String
    var attention: AgentAttention?
    /// 막힌 이유(권한·질문), 기다리는 상대 이름 같은 짧은 말.
    var detail: String?
    /// 지금 상태가 된 시각. 손이 갈 상태(막힘·오류)에서만 경과 시간을 보인다.
    var since: Date?
    /// 이 패널의 노치 알림. 있으면 이름표 끝에 지우기(×)가 붙는다 — 노치의 ×와 같은 일을 한다.
    var notice: NotchNotice?

    init(title: String, attention: AgentAttention? = nil, detail: String? = nil, since: Date? = nil) {
        self.title = title
        self.attention = attention
        self.detail = detail
        self.since = since
    }

    init(agent: PeerAgent, attention: AgentAttention, notice: NotchNotice? = nil, title: String? = nil) {
        self.title = title ?? agent.name
        self.attention = attention
        self.since = agent.since
        if let notice {
            // 노치와 같은 말, 같은 시각.
            self.notice = notice
            self.detail = notice.shortLabel
            self.since = notice.updatedAt
            return
        }
        switch attention {
        case .blocked:
            switch agent.reason {
            case "permission": detail = "권한"
            case "question": detail = "질문"
            default: detail = "확인"
            }
        case .error: detail = "실패"
        case .waiting: detail = agent.waitingOn.map { "\($0) 대기" }
        default: detail = nil
        }
    }

    /// 에이전트가 없는 패널의 터미널 알림.
    init(title: String, notice: NotchNotice) {
        self.init(title: title, attention: notice.state == "error" ? .error : .blocked,
                  detail: notice.shortLabel, since: notice.updatedAt)
        self.notice = notice
    }

    var showsAge: Bool { attention?.needsSEOL == true && since != nil }

    static func age(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(Int(seconds / 60))분" }
        if seconds < 86400 { return "\(Int(seconds / 3600))시간" }
        return "\(Int(seconds / 86400))일"
    }

    var help: String {
        var parts = [title]
        if let attention { parts.append(AgentStateMark.spokenName(attention)) }
        if let detail { parts.append(detail) }
        if let since, showsAge { parts.append(Self.age(since: since) + " 전부터") }
        var help = parts.joined(separator: " · ")
        if let notice { help += "\n" + notice.detailText }
        return help
    }
}

/// 워크스페이스 줄의 상태 칸. 손이 갈 상태(막힘·오류)가 있으면 그것을, 없으면 지금처럼
/// 최근 대화 점(진하기 = 최근성)을 그린다. 일하는 중은 원래 점의 스피너가 그대로 맡는다.
struct WorkspaceStatusMark: View {
    let attention: AgentAttention?
    let lastConversation: Date?
    let isGenerating: Bool

    var body: some View {
        if let attention, attention.needsSEOL {
            AgentStateMark(attention: attention)
                .help(AgentStateMark.spokenName(attention))
        } else {
            WorkspaceActivityDot(lastConversation: lastConversation,
                                 isGenerating: isGenerating || attention == .working)
        }
    }
}
