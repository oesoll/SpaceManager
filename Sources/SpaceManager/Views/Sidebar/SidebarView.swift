import SwiftUI

/// 워크스페이스를 넘기는 사이드바. 파일 목록은 뺐다 — 이 패널이 하는 일은 전환뿐이다.
/// 창의 라이트/다크를 따른다. 작업면보다 한 단 가라앉은 면이라 어느 쪽에서든 터미널이 주인공이다.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isCompact: Bool
    @State private var isHoveringTheme = false

    private var isDarkNow: Bool {
        switch appState.preferredAppearance {
        case "light": return false
        case "dark": return true
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("워크스페이스")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(Color(Chrome.textSecondary))
                    .lineLimit(1)
                    .opacity(isCompact ? 0 : 1)
                    .frame(width: isCompact ? 0 : nil, alignment: .leading)
                    .clipped()
                    .accessibilityHidden(isCompact)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button {
                        appState.showNewWorkspaceSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: Sidebar.iconSize, weight: .medium))
                            .foregroundStyle(Color(Chrome.textSecondary))
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Workspace")
                    .accessibilityLabel("New Workspace")
                    themeToggle
                }
                .opacity(isCompact ? 0 : 1)
                .frame(width: isCompact ? 0 : nil)
                .clipped()
                .allowsHitTesting(!isCompact)
                .accessibilityHidden(isCompact)
                sidebarToggle
                    .padding(.leading, isCompact ? 0 : 4)
            }
            .frame(height: 24)
            .padding(.horizontal, isCompact ? (Sidebar.compactWidth - 22) / 2 : 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                WorkspaceListView(isCompact: isCompact)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(Color(Chrome.sidebar))
    }

    private var themeToggle: some View {
        Button {
            appState.setAppearance(isDarkNow ? "light" : "dark")
        } label: {
            Image(systemName: isDarkNow ? "sun.max" : "moon")
                .font(.system(size: Sidebar.iconSize, weight: .medium))
                .foregroundStyle(Color(isHoveringTheme ? Chrome.textPrimary : Chrome.textSecondary))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringTheme = $0 }
        .help(isDarkNow ? "라이트 모드로 전환" : "다크 모드로 전환")
        .accessibilityLabel(isDarkNow ? "Light Mode" : "Dark Mode")
    }

    private var sidebarToggle: some View {
        Button {
            isCompact.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(Chrome.textSecondary))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCompact ? "사이드패널 펼치기" : "사이드패널 접기")
        .accessibilityLabel(isCompact ? "Expand Sidebar" : "Collapse Sidebar")
    }
}
