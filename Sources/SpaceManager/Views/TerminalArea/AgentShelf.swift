import SwiftUI

/// 오른쪽 노치: 이 워크스페이스에서 돌지만 sm 패널에는 없는 에이전트(SEOL 11/15). 에이전트가 띄운 일꾼,
/// 패널을 닫아 뒤로 간 세션 같은 것들이다.
///
/// 하니스 로고가 겹쳐 오른쪽으로 놓이고, 셋을 넘으면 "+N"으로 줄인다 — 화면 밖에서 무엇이 도는지가 한눈에
/// 보이는 게 할 일이다. 포인터를 올리면 목록이 노치에서 위로 펼쳐지고(노치가 원점이다), 이름을 누르면 미리보기가
/// 열린다. 펼침은 튀지 않는 스프링이고(눌러서 던진 움직임이 아니다), 동작 줄이기에서는 흐려지기만 한다.
struct AgentShelf: View {
    let agents: [ShelfAgent]
    let onOpen: (ShelfAgent) -> Void
    @State private var isExpanded = false
    @State private var collapse: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let avatar: CGFloat = 20
    static let overlap: CGFloat = 7
    static let shown = 3

    var body: some View {
        stack
            .padding(.horizontal, 10)
            .frame(height: WorkspaceTabStrip.height)
            .contentShape(Rectangle())
            .onHover { setHover($0) }
            .overlay(alignment: .bottomTrailing) {
                if isExpanded {
                    AgentShelfList(agents: agents) { agent in
                        isExpanded = false
                        onOpen(agent)
                    }
                    .onHover { setHover($0) }
                    // 노치 바로 위에서, 노치의 오른쪽 끝에 맞춰 펼쳐진다. 묶음은 노치 띠(노치 깊이 + 카드 아래 간격)
                    // 가운데에 서므로, 묶음 아래에서 노치 위까지는 그 띠의 절반 + 묶음 높이의 절반이다.
                    .alignmentGuide(.bottom) {
                        $0[.bottom] + (BottomNotch.height + ContentView.cardGap + WorkspaceTabStrip.height) / 2 + 6
                    }
                    .transition(reduceMotion ? .opacity
                                : .scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1.0),
                       value: isExpanded)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("화면 밖 에이전트 \(agents.count)개")
    }

    private var stack: some View {
        HStack(spacing: 6) {
            HStack(spacing: -Self.overlap) {
                ForEach(Array(agents.prefix(Self.shown).enumerated()), id: \.element.id) { index, row in
                    AgentAvatar(kind: row.kind, attention: row.attention)
                        // 앞의 것이 위에 — 가장 급한 것이 가려지지 않게.
                        .zIndex(Double(Self.shown - index))
                }
            }
            if agents.count > Self.shown {
                Text("+\(agents.count - Self.shown)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(Chrome.textSecondary))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0), value: agents.map(\.id))
    }

    /// 묶음과 펼친 목록 사이를 지나가는 동안 닫히지 않게 잠깐 기다린다.
    private func setHover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            isExpanded = true
        } else {
            let work = DispatchWorkItem { isExpanded = false }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
}

/// 하니스 로고 한 개. 둘레의 바탕색 테두리가 겹친 로고를 갈라 놓는다. 손이 가야 하는 상태면 오른쪽 아래에 작은 표시.
struct AgentAvatar: View {
    let kind: String
    var attention: AgentAttention?
    var size: CGFloat = AgentShelf.avatar

    var body: some View {
        ZStack {
            Circle().fill(Color(Chrome.raised))
            HarnessIcon(kind: kind)
                .foregroundStyle(Color(Chrome.textPrimary).opacity(0.85))
                .frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color(Chrome.canvas), lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            if let attention, attention == .blocked || attention == .error || attention == .working {
                Circle()
                    .fill(attention == .error ? Color.reconnectAmber : Color(Chrome.accent))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Color(Chrome.canvas), lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
        }
    }
}

/// 펼친 목록. 떠 있는 층이라 반투명 재질 위에 놓고, 아래 터미널과는 옅은 그림자로 가른다.
private struct AgentShelfList: View {
    let agents: [ShelfAgent]
    let onOpen: (ShelfAgent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("화면 밖에서 도는 에이전트 · \(agents.count)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Color(Chrome.textSecondary))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(agents) { row in
                        AgentShelfRow(agent: row) { onOpen(row) }
                    }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
    }
}

private struct AgentShelfRow: View {
    let agent: ShelfAgent
    let open: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(kind: agent.kind, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(Chrome.textPrimary))
                    .lineLimit(1)
                if let parent = agent.parent {
                    Text("\(parent)이 띄움")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(Chrome.textTertiary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            AgentStateMark(attention: agent.attention)
            if let lastActive = agent.lastActive {
                Text(PaneBadge.age(since: lastActive))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: agent.parent == nil ? 28 : 36)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(isHovering ? Chrome.hover : .clear)))
        .scaleEffect(isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.1), value: isPressed)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 누르는 순간 눌린 것이 보이고, 놓을 때 연다.
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false })
        .onTapGesture(perform: open)
        .help("\(agent.name) 미리보기")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(AgentStateMark.spokenName(agent.attention))")
        .accessibilityAddTraits(.isButton)
    }
}

/// 미리보기: 그 세션에 붙은 진짜 터미널을 노치 위에 띄운다. 목록에는 도는 세션만 있어 붙어도 깨우지 않는다.
/// 붙은 동안은 입력하면 에이전트에게 간다. 닫으면 붙기만 끊고 세션은 계속 돈다.
final class AgentPreview: ObservableObject {
    @Published private(set) var agent: ShelfAgent?
    private(set) var session: TerminalSession?

    func open(_ agent: ShelfAgent, workingDirectory: String) {
        guard self.agent?.id != agent.id else { return }
        session?.cleanup()
        session = TerminalSession(name: agent.name, workingDirectory: workingDirectory,
                                  attachment: .agent(name: agent.name, host: agent.host, agent: nil))
        self.agent = agent
    }

    func close() {
        session?.cleanup()
        session = nil
        agent = nil
    }
}

struct AgentPreviewCard: View {
    let agent: ShelfAgent
    @ObservedObject var session: TerminalSession
    let attention: AgentAttention
    let onOpenInPane: () -> Void
    let onOpenInTab: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentAvatar(kind: agent.kind, size: 18)
                Text(agent.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(Chrome.textPrimary))
                AgentStateMark(attention: attention)
                if let parent = agent.parent {
                    Text("\(parent)이 띄움")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(Chrome.textTertiary))
                }
                Spacer(minLength: 8)
                PreviewButton(title: "새 탭으로", isPrimary: false, action: onOpenInTab)
                PreviewButton(title: "패널로 열기", isPrimary: true, action: onOpenInPane)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(Chrome.textSecondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("미리보기 닫기 (세션은 계속 돈다)")
                .accessibilityLabel("미리보기 닫기")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            AgentTerminalView(session: session)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 4))
        }
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ContentView.cardRadius, style: .continuous)
            .strokeBorder(Color(Chrome.hairline), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .onAppear { session.focusTerminal() }
    }
}

private struct PreviewButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(Color(isPrimary ? Chrome.textPrimary : Chrome.textSecondary))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(isPrimary ? Chrome.accent.withAlphaComponent(isHovering ? 0.24 : 0.16)
                                          : (isHovering ? Chrome.hover : .clear))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { isHovering = $0 }
    }
}

/// 누르는 순간 살짝 눌린다(놓을 때가 아니라).
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
