import SwiftUI
import AppKit

extension Color {
    /// 재연결 상태. tmux 메시지 줄(노랑 바탕·검정 글자)을 따라 터미널 안의 TUI 문구처럼 읽힌다.
    static let reconnectAmber = Color(red: 0.84, green: 0.69, blue: 0.37)
}

/// 작업 창의 색. 면 셋(바탕·사이드바·작업면)은 고른 명도 간격으로 한 단씩 올라가고,
/// 카드는 그림자 대신 머리카락 선 하나로 맺는다. 글자 세 단, 선택·호버 두 단이 전부다. 위계는 명도 차이로만 만들고 강조색은 활동 표시에만 쓴다 — 선택까지 색으로
/// 칠하면 "지금 무언가 돌고 있다"는 신호가 묻힌다. 라이트/다크는 창의 외형을 따라
/// 풀리는 동적 색이라, 뷰는 외형을 몰라도 된다.
enum Chrome {
    /// 카드 뒤의 창 바탕. 그라데이션 없이 한 색이다.
    static let canvas = dynamic(dark: 0x0f0f10, light: 0xe8e8e6)
    /// 사이드바 카드. 바탕과 작업면 사이의 한 단이라 시선이 터미널에 머문다.
    static let sidebar = dynamic(dark: 0x171719, light: 0xf5f5f4)
    /// 상단 막대와 터미널이 함께 쓰는 작업면. 터미널 팔레트의 배경과 같아야 한다.
    static let pane = dynamic(dark: 0x1e1e1e, light: 0xffffff)
    /// 면과 면 사이의 1pt 선. 그림자 대신 이것 하나로 구획한다.
    static let hairline = dynamic(dark: 0x2a2a2d, light: 0xdcdcda)
    static let selection = dynamic(dark: 0x2a2a2d, light: 0xe6e6e4)
    static let hover = dynamic(dark: 0x202023, light: 0xececea)
    /// 작업면 위에 뜨는 패널(활동 목록).
    static let raised = dynamic(dark: 0x252528, light: 0xffffff)

    static let textPrimary = dynamic(dark: 0xececee, light: 0x1d1d1f)
    static let textSecondary = dynamic(dark: 0xa3a3a8, light: 0x5c5c61)
    static let textTertiary = dynamic(dark: 0x6f6f75, light: 0x9b9ba0)
    /// 활동 점. tmux(테두리·현재 탭·메시지)와 같은 warmPink라 앱과 터미널이 한 강조색을 쓴다.
    /// 라이트는 흰 바탕에서 읽히도록 한 단 짙다.
    static let accent = dynamic(dark: 0xf27380, light: 0xc8485a)

    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255,
                           alpha: 1)
        }
    }
}

extension Color {
    init(_ chrome: NSColor) { self.init(nsColor: chrome) }
}

/// 워크스페이스 폴더 아이콘 색. 여러 워크스페이스를 색으로 묶어 접힌 레일에서도
/// 한눈에 고를 수 있게 한다. 채도를 눌러 어느 면에서도 아이콘 이상으로 튀지 않는다.
enum FolderTint: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "빨강"
        case .orange: "주황"
        case .yellow: "노랑"
        case .green: "초록"
        case .teal: "청록"
        case .blue: "파랑"
        case .purple: "보라"
        case .pink: "분홍"
        }
    }

    var color: NSColor {
        switch self {
        case .red: Chrome.dynamic(dark: 0xe5807a, light: 0xc4483f)
        case .orange: Chrome.dynamic(dark: 0xe39a63, light: 0xc06a1f)
        case .yellow: Chrome.dynamic(dark: 0xd9bd6a, light: 0xa07d10)
        case .green: Chrome.dynamic(dark: 0x8cc792, light: 0x3d8a49)
        case .teal: Chrome.dynamic(dark: 0x6fc2c4, light: 0x17848a)
        case .blue: Chrome.dynamic(dark: 0x7ea6f2, light: 0x2f6bd6)
        case .purple: Chrome.dynamic(dark: 0xb79cf0, light: 0x7a4fc4)
        case .pink: Chrome.dynamic(dark: 0xe590b8, light: 0xb84a80)
        }
    }

    /// 지정이 없으면 nil — 아이콘은 글자색 단계를 따른다.
    static func color(for raw: String?) -> NSColor? {
        raw.flatMap(FolderTint.init(rawValue:))?.color
    }
}

/// 사이드바 공통 룩 — 행 높이·아이콘 크기·라운딩을 한 곳에서 통일한다.
/// 섹션마다 수치가 조금씩 다르면 패널 전체가 미묘하게 어수선해 보인다.
enum Sidebar {
    /// Quick 창 사이드바 폭.
    static let expandedWidth: CGFloat = 240
    /// 작업 창 사이드바. 폴더 아이콘, 이름, 실행 위치가 한 줄에 들어갈 만큼만 —
    /// 넓은 사이드바는 그만큼 터미널 열을 깎는다. 긴 이름은 끝을 줄이고 툴팁에 전부 있다.
    static let workspaceWidth: CGFloat = 184
    static let compactWidth: CGFloat = 44
    static let collapseAnimation = Animation.easeInOut(duration: 0.48)
    /// Quick 창 행의 라운딩·여백. 작업 창 목록은 아래 `list*` 값을 쓴다.
    static let rowCornerRadius: CGFloat = 10
    static let rowHorizontalPadding: CGFloat = 12
    static let listCornerRadius: CGFloat = 6
    static let listInset: CGFloat = 8
    /// 모든 워크스페이스 행이 같은 높이다. 선택된 행만 부제를 달아 키우면 목록의 리듬이 깨진다.
    static let rowHeight: CGFloat = 30
    static let tabRowHeight: CGFloat = 26
    static let rowVerticalPadding: CGFloat = 8
    static let iconSize: CGFloat = 13
    static let iconFrame: CGFloat = 16
}

/// 홈 화면의 한글 글자. Fine과 같은 서체 — 없으면 `Font.custom`이 시스템 서체로 떨어진다.
enum HomeFont {
    static func greeting(_ size: CGFloat) -> Font { .custom("Pretendard-SemiBold", size: size) }
    static let note = Font.custom("Pretendard-Medium", size: 14)
    static let prompt = Font.custom("Pretendard-Regular", size: 16)
    static let caption = Font.custom("Pretendard-Medium", size: 11)
}

/// 사이드바 섹션 헤더 — 워크스페이스 / 파일이 같은 얼굴을 갖도록 공용화.
/// 작고 옅은 라벨이어야 목록이 주인공이 된다. 대문자 굵은 영문 라벨은 목록보다 크게 외쳤다.
/// trailing에는 섹션의 대표 액션 하나만 놓는다 (액션이 늘면 메뉴로 접는다).
struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .tracking(0.2)
                .foregroundColor(.secondary.opacity(0.85))
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

/// 헤르메스(Quick) 창 전용 사이드바 섹션 헤더 — claude.ai 데스크톱 감성(작고 옅은 라벨 위계)
struct QuickSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.3)
                .foregroundColor(.secondary.opacity(0.95))
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// 라이트/다크는 창별이다 — ContentView의 preferredColorScheme이 창(씬) 단위로
/// 적용한다. 여기는 tmux 쪽 연동만 남는다.
enum AppearanceManager {
    /// 앱 무드를 tmux 상태바까지 연장한다 (~/.smux/bin/smux-theme).
    ///
    /// 라이트로 갈 때만 soft를 호출한다 — 문제의 본질이 "화이트 크롬 위의 솔리드
    /// pill 충돌"이고, 다크에서의 취향은 유저마다 갈리는 영역이라(현재 SEOL은
    /// 다크에서도 soft 선호) 다크 전환 시 강제로 pill을 씌우면 취향과 싸우는
    /// 동기화가 된다. 다크에서 pill을 원하게 되면 호출부에 else 분기로 dark 추가.
    /// tmux 상태바는 전역이므로, 유저가 마지막으로 토글한 창의 무드를 따른다.
    static func syncTmuxThemeToSoft() {
        // 콜드부트 창에는 어떤 tmux 명령도 금지 (continuum 가드 오판 방지)
        guard TmuxBootstrap.serverSocketExists, !TmuxBootstrap.isInColdBootWindow else { return }
        let switcher = NSHomeDirectory() + "/.smux/bin/smux-theme"
        guard FileManager.default.isExecutableFile(atPath: switcher) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: switcher)
            process.arguments = ["soft"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()   // best-effort — 실패해도 앱 테마 전환은 이미 완료
        }
    }
}
