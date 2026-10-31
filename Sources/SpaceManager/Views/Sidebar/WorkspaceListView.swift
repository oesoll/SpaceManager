import SwiftUI
import UniformTypeIdentifiers

/// List of workspaces in the sidebar
struct WorkspaceListView: View {
    @EnvironmentObject var appState: AppState
    var isCompact = false
    @ObservedObject private var activity = RecentActivityScanner.shared
    @ObservedObject private var peers = PeerDirectory.shared
    @ObservedObject private var layouts = LayoutDirectory.shared
    @State private var draggingWorkspace: Workspace?

    /// 이 워크스페이스(루트 및 하위 경로)에서의 마지막 Claude 대화 시각
    private func lastConversation(for workspace: Workspace) -> Date? {
        (activity.workspaceActivityByHost[workspace.remoteHost ?? ""] ?? [:])
            .filter { $0.key == workspace.rootPath || $0.key.hasPrefix(workspace.rootPath + "/") }
            .map(\.value)
            .max()
    }

    /// 이 워크스페이스(루트 및 하위 경로)의 transcript가 지금 자라고 있는지
    private func isGenerating(_ workspace: Workspace) -> Bool {
        (activity.generatingDirectoriesByHost[workspace.remoteHost ?? ""] ?? []).contains {
            $0 == workspace.rootPath || $0.hasPrefix(workspace.rootPath + "/")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if appState.workspaces.isEmpty {
                Text("워크스페이스가 없습니다")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(Chrome.textTertiary))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .opacity(isCompact ? 0 : 1)
                    .accessibilityHidden(isCompact)
            } else {
                ForEach(appState.workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isCompact: isCompact,
                        isSelected: appState.selectedWorkspace?.id == workspace.id,
                        lastConversation: lastConversation(for: workspace),
                        isGenerating: isGenerating(workspace),
                        attention: appState.agentRollup(for: workspace, directory: peers),
                        tint: FolderTint.color(for: workspace.folderColor),
                        onChangeHost: { changeHost(workspace, to: $0) }
                    )
                    .onTapGesture {
                        appState.selectWorkspace(workspace)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { appState.selectWorkspace(workspace) }
                    .onDrag {
                        draggingWorkspace = workspace
                        return NSItemProvider(object: workspace.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: WorkspaceDropDelegate(
                            target: workspace,
                            workspaces: { appState.workspaces },
                            dragging: $draggingWorkspace
                        ) { source, destination in
                            appState.moveWorkspace(from: source, to: destination)
                        }
                    )
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.rootPath)
                        }
                        Button("Rename...") {
                            let alert = NSAlert()
                            alert.messageText = "워크스페이스 이름"
                            alert.informativeText = "비워두면 폴더명으로 돌아갑니다."
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                            input.stringValue = workspace.customName ?? ""
                            input.placeholderString = workspace.name
                            alert.accessoryView = input
                            if alert.runModal() == .alertFirstButtonReturn {
                                appState.renameWorkspace(workspace, to: input.stringValue.isEmpty ? nil : input.stringValue)
                            }
                        }
                        Button("Edit tmux Session Name...") {
                            let alert = NSAlert()
                            alert.messageText = "tmux 세션명"
                            alert.informativeText = "비워두면 이름에서 자동 파생됩니다. 현재: \(workspace.effectiveTmuxSessionName)"
                            alert.addButton(withTitle: "저장")
                            alert.addButton(withTitle: "취소")
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
                            input.stringValue = workspace.tmuxSessionName ?? ""
                            input.placeholderString = workspace.effectiveTmuxSessionName
                            alert.accessoryView = input
                            if alert.runModal() == .alertFirstButtonReturn {
                                appState.setTmuxSessionName(workspace, to: input.stringValue)
                            }
                        }
                        Menu("실행 위치") {
                            WorkspaceHostChoices(workspace: workspace) { changeHost(workspace, to: $0) }
                        }
                        Menu("폴더 색") {
                            Button { appState.setFolderColor(workspace, to: nil) } label: {
                                if workspace.folderColor == nil { Label("기본", systemImage: "checkmark") } else { Text("기본") }
                            }
                            Divider()
                            ForEach(FolderTint.allCases) { tint in
                                Button { appState.setFolderColor(workspace, to: tint.rawValue) } label: {
                                    if workspace.folderColor == tint.rawValue {
                                        Label(tint.title, systemImage: "checkmark")
                                    } else {
                                        Text(tint.title)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("새 셸 탭") { appState.selectWorkspace(workspace); appState.addShellTab() }
                        if TmuxBootstrap.isTmuxAvailable {
                            Button("새 tmux 탭") { appState.selectWorkspace(workspace); appState.addTmuxTab() }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteWorkspace(workspace)
                        }
                    }

                    // 선택된 워크스페이스의 탭 폴더링 — 탭이 2개 이상일 때만 하위 목록 표시.
                    // 배치 데이터가 있으면 그 탭(세션 층의 원본)을, 없으면 지금까지의 tmux 탭을 보인다.
                    if appState.selectedWorkspace?.id == workspace.id,
                       let layout = appState.layout(for: workspace, directory: layouts), layout.tabs.count > 1 {
                        VStack(spacing: 0) {
                            ForEach(layout.tabs) { tab in
                                LayoutTabRow(
                                    name: tab.name,
                                    isSelected: appState.displayedTab(of: layout)?.id == tab.id,
                                    attention: appState.layoutRollup(tab: tab, in: layout, directory: peers),
                                    onSelect: { appState.selectLayoutTab(tab.id, in: layout) }
                                )
                            }
                        }
                        .frame(width: (isCompact ? Sidebar.compactWidth : Sidebar.workspaceWidth) - 12)
                        .opacity(isCompact ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!isCompact)
                        .accessibilityHidden(isCompact)
                    } else if appState.selectedWorkspace?.id == workspace.id && appState.sessions.count > 1
                                && appState.layout(for: workspace, directory: layouts) == nil {
                        VStack(spacing: 0) {
                            ForEach(appState.sessions) { session in
                                WorkspaceTabRow(
                                    session: session,
                                    isSelected: appState.selectedSession?.id == session.id,
                                    attention: appState.agentRollup(forTab: session, directory: peers),
                                    onSelect: {
                                        appState.selectSession(session)
                                    },
                                    onClose: { appState.removeSession(session) }
                                )
                            }
                        }
                        // Retain these rows' height so every folder keeps its Y
                        // position while names and subordinate tabs fade away.
                        .frame(width: (isCompact ? Sidebar.compactWidth : Sidebar.workspaceWidth) - 12)
                        .opacity(isCompact ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!isCompact)
                        .accessibilityHidden(isCompact)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func changeHost(_ workspace: Workspace, to host: String) {
        if let error = appState.setRemoteHost(workspace, to: host) {
            let alert = NSAlert()
            alert.messageText = "실행 위치를 변경할 수 없습니다"
            alert.informativeText = error
            alert.runModal()
        }
    }
}

/// The personal setup has two usual destinations; other SSH aliases remain
/// available through the editor. Add host discovery if more saved hosts are needed.
struct WorkspaceHostChoices: View {
    let workspace: Workspace
    let onChange: (String) -> Void

    var body: some View {
        hostButton("이 Mac", host: "")
        hostButton("아치 · arch", host: "arch")
        if let host = workspace.remoteHost, !host.isEmpty, host != "arch" {
            hostButton(host, host: host)
        }
        Divider()
        Button("다른 SSH 호스트…") {
            let alert = NSAlert()
            alert.messageText = "실행할 SSH 호스트"
            alert.informativeText = "SSH 설정의 호스트 별칭을 입력하세요. 원격 작업 폴더는 \(workspace.remoteDirectory.shellExpression)입니다. 파일은 자동으로 복사되지 않습니다."
            alert.addButton(withTitle: "연결")
            alert.addButton(withTitle: "취소")
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            input.stringValue = workspace.remoteHost ?? ""
            input.placeholderString = "arch"
            alert.accessoryView = input
            if alert.runModal() == .alertFirstButtonReturn { onChange(input.stringValue) }
        }
        Divider()
        Text("실행 위치만 변경 · 파일 자동 이전 없음")
    }

    private func hostButton(_ title: String, host: String) -> some View {
        Button { onChange(host) } label: {
            if (workspace.remoteHost ?? "") == host {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// 활동 점 둘레의 스피너.
///
/// SwiftUI `repeatForever` 회전은 매 프레임 메인 스레드 트랜잭션을 커밋하고,
/// `isMovableByWindowBackground` 창에서는 커밋마다 AppKit이 뷰 트리 전체로
/// 드래그 영역을 다시 계산한다(스피너 하나에 CPU +25%p 측정). 회전을
/// CABasicAnimation으로 렌더 서버에 넘겨 메인 스레드가 프레임마다 깨지 않게 한다.
private struct ActivitySpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivitySpinnerView { ActivitySpinnerView() }
    func updateNSView(_ nsView: ActivitySpinnerView, context: Context) {}
}

/// 장식 전용 레이어 뷰. 행 안에 박힌 AppKit 뷰는 SwiftUI 탭 제스처보다 먼저
/// hit-test되고, 배경 드래그 창에서는 투명 NSView 클릭이 창 이동으로 바뀐다.
/// 스피너가 도는 행을 눌러도 선택·툴팁이 그대로 동작하도록 포인터를 통과시킨다.
final class ActivitySpinnerView: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 1.2
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 동적 색은 CALayer에 넘길 때 고정되므로 외형이 바뀔 때마다 다시 푼다.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = Chrome.accent.withAlphaComponent(0.85).cgColor
        }
    }

    override func layout() {
        super.layout()
        // 독립 sublayer의 frame/path 변경은 기본 0.25초 암묵 애니메이션을 탄다.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.6, dy: 0.6), transform: nil)
        CATransaction.commit()
    }

    // 창에 붙을 때마다 다시 건다 — 창에서 떨어지면 CA가 애니메이션을 제거한다.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        arc.removeAnimation(forKey: "spin")
        guard window != nil else { return }
        viewDidChangeEffectiveAppearance()
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi   // AppKit 좌표계(y 위)에서 시계 방향
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
}

/// 워크스페이스 행의 활동 점.
///
/// 점의 진하기 = 마지막 Claude 대화의 최근성. 방금 대화했으면 선명한 강조색,
/// 시간이 지날수록 흐려지다 24시간이 지나면 사라진다 — 사이드바만 훑어도
/// "요즘 만지는 워크스페이스"가 도드라진다. 에이전트가 지금 출력을 만드는 중이면
/// 점 둘레에 스피너가 돈다. 자리는 항상 확보해 상태가 오가도 행이 밀리지 않는다.
struct WorkspaceActivityDot: View {
    let lastConversation: Date?
    let isGenerating: Bool

    /// 최근성 → 진하기. 4시간 반감기의 지수 곡선으로 방금/3시간/12시간/어제를
    /// 눈으로 구분하되, 24시간 경계에서는 완전히 사라진다.
    static func recencyOpacity(age: TimeInterval, window: TimeInterval = RecentActivityScanner.dotWindow) -> Double? {
        guard age >= 0, age < window else { return nil }
        let halfLife: TimeInterval = 4 * 3600
        return 0.08 + 0.92 * pow(0.5, age / halfLife)
    }

    private var opacity: Double? {
        guard let lastConversation else { return nil }
        return Self.recencyOpacity(age: -lastConversation.timeIntervalSinceNow)
    }

    var body: some View {
        ZStack {
            if let opacity {
                Circle()
                    .fill(Color(Chrome.accent))
                    .frame(width: 6, height: 6)
                    .opacity(opacity)

            }

            if isGenerating {
                ActivitySpinner()
                    .frame(width: 12, height: 12)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeInOut(duration: 0.4), value: opacity == nil)
        .animation(.easeInOut(duration: 0.4), value: isGenerating)
        .help(helpText)
    }

    private var helpText: String {
        guard let lastConversation else { return "" }
        let minutes = Int(-lastConversation.timeIntervalSinceNow) / 60
        let when = minutes < 1 ? "방금" : minutes < 60 ? "\(minutes)분 전" : "\(minutes / 60)시간 전"
        return isGenerating ? "에이전트 응답 생성 중 · 마지막 대화 \(when)" : "마지막 대화 \(when)"
    }
}

/// 배치 데이터의 탭 행. 모양은 아래 WorkspaceTabRow와 같고, 닫기는 없다(탭은 세션 층 명령으로 닫는다).
struct LayoutTabRow: View {
    let name: String
    let isSelected: Bool
    var attention: AgentAttention?
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(Color(isSelected ? Chrome.textPrimary : Chrome.textSecondary))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let attention, attention >= .working {
                AgentStateMark(attention: attention)
                    .help(AgentStateMark.spokenName(attention))
            }
        }
        .frame(height: Sidebar.tabRowHeight)
        .padding(.leading, Sidebar.listInset + Sidebar.iconFrame + 6)
        .padding(.trailing, 4 + 14)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: Sidebar.listCornerRadius, style: .continuous)
                    .fill(Color(Chrome.hover))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

/// 워크스페이스 하위 탭 행 (폴더링 목록의 항목). 이름은 워크스페이스 이름과 같은 세로줄에서
/// 시작한다. 정상(실행 중)은 아무 표시도 없고, 재연결·종료처럼 손이 갈 상태만 점으로 남긴다.
struct WorkspaceTabRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    var attention: AgentAttention?
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    /// 메인 탭은 워크스페이스의 고정 앵커라 닫아도 다음 방문에 재생성된다 —
    /// 닫히는 척만 하는 ×를 보여주느니 처음부터 닫기 대상에서 제외한다.
    private var isClosable: Bool { session.kind != .tmuxMain }

    private var statusColor: Color? {
        if session.isReconnecting { return .reconnectAmber }
        if !session.isRunning { return Color(Chrome.textTertiary) }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(session.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(Color(isSelected ? Chrome.textPrimary : Chrome.textSecondary))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                    .help(session.isReconnecting ? "재연결 중" : "종료됨")
            } else if let attention, attention >= .working {
                AgentStateMark(attention: attention)
                    .help(AgentStateMark.spokenName(attention))
            }

            // 자리를 항상 확보하고 투명도로만 나타낸다 — 호버 때 요소가 끼어들면
            // 텍스트가 밀리며 목록이 출렁인다
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(Chrome.textTertiary))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .opacity(isClosable && isHovering ? 1 : 0)
            .allowsHitTesting(isClosable && isHovering)
        }
        .frame(height: Sidebar.tabRowHeight)
        // 워크스페이스 이름과 같은 세로줄에서 시작한다(행 여백 + 아이콘 칸 + 간격).
        .padding(.leading, Sidebar.listInset + Sidebar.iconFrame + 6)
        .padding(.trailing, 4)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: Sidebar.listCornerRadius, style: .continuous)
                    .fill(Color(Chrome.hover))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    let target: Workspace
    let workspaces: () -> [Workspace]
    @Binding var dragging: Workspace?
    let moveAction: (_ source: Int, _ destination: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let current = workspaces()
        guard let sourceIndex = current.firstIndex(of: dragging),
              let targetIndex = current.firstIndex(of: target) else { return }

        let destinationIndex = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        moveAction(sourceIndex, destinationIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Single workspace row
///
/// 폴더 아이콘, 이름, 활동 점, 실행 위치(mac·arch…). 실행 위치는 글자로 늘 보이고 누르면
/// 바꿀 수 있다 — 맥·아치·NUC가 섞인 목록에서 "어디서 도는가"는 매번 필요한 정보다.
/// 경로는 툴팁, 새 탭은 컨텍스트 메뉴에 있다. 아이콘 색은 워크스페이스마다 고를 수 있어,
/// 접힌 레일에서는 색 있는 폴더만으로 고른다.
struct WorkspaceRow: View {
    let workspace: Workspace
    var isCompact = false
    let isSelected: Bool
    var lastConversation: Date?
    var isGenerating: Bool = false
    var attention: AgentAttention?
    /// `workspace.folderColor`를 따로 받는다 — Workspace의 ==는 id만 비교해서
    /// 값만 바뀐 행은 SwiftUI가 다시 그리지 않을 수 있다.
    var tint: NSColor?
    var onChangeHost: ((String) -> Void)?
    @State private var isHovering = false

    private var hostLabel: String {
        workspace.isRemote ? (workspace.remoteHost ?? "") : "mac"
    }

    private var iconColor: Color {
        if let tint { return Color(tint) }
        return Color(isSelected ? Chrome.textPrimary : Chrome.textSecondary)
    }

    var body: some View {
        Group {
            if isCompact {
                folderIcon
                    .overlay(alignment: .topTrailing) {
                        WorkspaceStatusMark(attention: attention, lastConversation: lastConversation, isGenerating: isGenerating)
                            .offset(x: 7, y: -6)
                    }
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    folderIcon
                    Text(workspace.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(Color(isSelected ? Chrome.textPrimary : Chrome.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    WorkspaceStatusMark(attention: attention, lastConversation: lastConversation, isGenerating: isGenerating)
                    Menu {
                        WorkspaceHostChoices(workspace: workspace) { onChangeHost?($0) }
                    } label: {
                        Text(hostLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(Chrome.textTertiary))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("실행 위치 변경")
                }
                .padding(.leading, Sidebar.listInset)
                .padding(.trailing, Sidebar.listInset)
            }
        }
        .frame(height: Sidebar.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: Sidebar.listCornerRadius, style: .continuous)
                    .fill(Color(isSelected ? Chrome.selection : Chrome.hover))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("\(workspace.name)\n\(workspace.isRemote ? (workspace.remoteHost ?? "") + ":" : "")\(workspace.rootPath)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var folderIcon: some View {
        Image(systemName: isSelected ? "folder.fill" : "folder")
            .font(.system(size: Sidebar.iconSize, weight: .medium))
            .foregroundColor(iconColor)
            .frame(width: Sidebar.iconFrame)
    }
}
