import SwiftUI
import AppKit

/// 나눈 탭. tmux가 그리던 패널 테두리·이름·포커스 표시를 sm이 그린다.
///
/// herdr의 기본값(`pane_gaps`)을 sm의 카드 말로 옮겼다: 패널은 선을 나눠 쓰지 않고 저마다 카드가
/// 되어, 사이드바 카드와 같은 간격·라운딩으로 바탕 위에 선다. 상자 안에 상자를 만들지 않는다.
/// 포커스된 카드만 테두리가 분홍이다(SEOL의 tmux 활성 테두리와 같은 색). 카드 사이 틈이 곧
/// 크기 조절 손잡이다.
///
/// 패널은 화면 좌표로 절대 배치한다. 나누거나 닫아도 남은 패널의 뷰가 다시 만들어지지 않아야
/// 터미널이 다시 붙지 않는다(ForEach의 id가 패널 id다).
struct TabPanesView: View {
    @ObservedObject var group: PaneGroup
    /// 패널 이름표에 쓸 글. 에이전트 매칭은 부르는 쪽이 한다.
    let badge: (TerminalSession) -> PaneBadge
    /// 고르는 중인 자리에 띄울 상자.
    var picker: ((UUID) -> AnyView)?

    static let gap = ContentView.cardGap
    static let radius = ContentView.cardRadius

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let layout = group.isZoomed ? PaneLayout.pane(group.focused) : group.layout
            let frames = layout.frames(in: bounds, divider: Self.gap)
            let dividers = layout.dividers(in: bounds, divider: Self.gap)
            ZStack(alignment: .topLeading) {
                ForEach(group.paneIDs, id: \.self) { id in
                    if let frame = frames[id], group.picking.contains(id), let picker {
                        PickerCard(isFocused: group.focused == id) { picker(id) }
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    } else if let frame = frames[id], let session = group.session(for: id) {
                        PaneCard(session: session,
                                 badge: badge(session),
                                 isFocused: group.focused == id && group.isSplit,
                                 isZoomed: group.isZoomed,
                                 onFocus: { group.focus(id) },
                                 onClose: id == group.anchor.id ? nil : { group.close(id) },
                                 onZoom: { group.toggleZoom() })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(Array(dividers.enumerated()), id: \.offset) { _, divider in
                    GapHandle(divider: divider) { ratio in group.setRatio(ratio, at: divider.path) }
                }
            }
            .coordinateSpace(name: TabPanesView.space)
        }
    }

    static let space = "TabPanes"
}

/// 패널 하나 = 카드 하나. 카드 윗머리에 이름표를 쓴다 — 바탕도 구분선도 없는 글자 한 줄이라
/// 막대가 아니라 카드의 제목으로 읽힌다. 테두리 위에 얹는 tmux식 이름표는 8pt 틈과 창 윗변에
/// 끼어 답답했다(10/31 캡처).
private struct PaneCard: View {
    @ObservedObject var session: TerminalSession
    let badge: PaneBadge
    let isFocused: Bool
    let isZoomed: Bool
    let onFocus: () -> Void
    let onClose: (() -> Void)?
    let onZoom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneLegend(badge: badge, isFocused: isFocused, isZoomed: isZoomed)
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(isZoomed ? "확대 끝내기" : "이 패널 확대", action: onZoom)
                    if let onClose {
                        Divider()
                        Button("패널 닫기", action: onClose)
                    }
                }
            AgentTerminalView(session: session)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 4))
        }
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous)
                .strokeBorder(Color(isFocused ? Chrome.accent : Chrome.hairline), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .background(PaneFocusMonitor(onPress: onFocus))
    }
}

/// 고르는 중인 자리. 터미널 대신 상자가 카드 안에 뜬다 — 고른 것이 바로 이 자리에서 열린다.
private struct PickerCard<Content: View>: View {
    let isFocused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 28)
        }
        .scrollIndicators(.never)
        .background(Color(Chrome.pane))
        .clipShape(RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TabPanesView.radius, style: .continuous)
                .strokeBorder(Color(isFocused ? Chrome.accent : Chrome.hairline), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

/// 이름표: 상태 표시, 이름, 막힌 이유, 경과 시간.
/// 포커스된 패널만 이름이 진하다 — 강조색은 상태 표시와 포커스 테두리에만 쓴다.
private struct PaneLegend: View {
    let badge: PaneBadge
    let isFocused: Bool
    let isZoomed: Bool

    static let height: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            // 표시가 없어도 자리는 둔다 — 상태가 오가도 이름이 밀리지 않는다(사이드바와 같다).
            AgentStateMark(attention: badge.attention)
            Text(badge.title)
                .font(.system(size: 11.5, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(Color(isFocused ? Chrome.textPrimary : Chrome.textSecondary))
            if let detail = badge.detail {
                Text(detail)
                    .font(.system(size: 11, weight: badge.attention == .blocked ? .semibold : .regular))
                    .foregroundStyle(badge.attention == .blocked ? Color(Chrome.accent) : Color(Chrome.textTertiary))
            }
            if badge.showsAge, let since = badge.since {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(PaneBadge.age(since: since, now: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color(Chrome.textTertiary))
                }
            }
            if isZoomed {
                Text("확대")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .help(badge.help)
    }
}

/// 카드 사이 틈. 보이지 않는 손잡이라 끌면 두 패널의 경계가 손가락을 1:1로 따라간다.
private struct GapHandle: View {
    let divider: PaneDivider
    let onRatio: (Double) -> Void
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: divider.line.width, height: divider.line.height)
            .offset(x: divider.line.minX, y: divider.line.minY)
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TabPanesView.space))
                    .onChanged { value in
                        onRatio(divider.ratio(at: value.location, divider: TabPanesView.gap))
                    }
            )
    }
}

/// 패널 안 어디를 눌러도 그 패널로 포커스가 옮겨 간다. 터미널 표면(AppKit 뷰)이 마우스를 먼저 받으므로
/// SwiftUI 제스처로는 못 잡는다 — 창의 마우스 다운을 엿보고 이벤트는 그대로 흘려보낸다.
/// 누르는 순간 옮긴다(놓을 때가 아니라).
private struct PaneFocusMonitor: NSViewRepresentable {
    let onPress: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onPress = onPress
    }

    final class MonitorView: NSView {
        var onPress: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.onPress?() }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
