import AppKit
import SwiftUI

enum GlassSurfaceRole: Equatable {
    case canvasDark
    case canvasLight
    case workspaceSidebar
    case quickSidebar
}

/// 작업 창의 면은 `Chrome`의 단색 토큰(바탕·사이드바·작업면)이다. 여기 캔버스 색은
/// Quick 창의 카드 뒤에만 쓰인다. Quick 사이드바만 behind-window blur를 쓴다.
enum GlassSurfacePolicy {
    static func canvasColor(for windowKind: WindowKind, isDark: Bool) -> NSColor {
        if windowKind == .quick {
            return .windowBackgroundColor
        }
        return canvasColor(for: isDark ? .canvasDark : .canvasLight)
    }

    static func material(for role: GlassSurfaceRole) -> NSVisualEffectView.Material {
        switch role {
        case .canvasDark, .canvasLight:
            return .underWindowBackground
        case .workspaceSidebar, .quickSidebar:
            return .sidebar
        }
    }

    static func canvasColor(for role: GlassSurfaceRole) -> NSColor {
        switch role {
        case .canvasDark:
            return NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1)
        case .canvasLight:
            return NSColor(srgbRed: 0.075, green: 0.075, blue: 0.082, alpha: 1)
        case .workspaceSidebar, .quickSidebar:
            preconditionFailure("Sidebar roles do not have a canvas color")
        }
    }

    /// 터미널 표면 둘레(여백)도 팔레트 배경으로 보이게 카드가 같은 색을 깐다.
    /// 작업 창은 창의 라이트/다크를 따르는 작업면 색이다.
    static func terminalCardColor(for windowKind: WindowKind) -> NSColor {
        switch windowKind {
        case .workspace:
            return Chrome.pane
        case .quick:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

/// Quick 창 카드 뒤의 바탕. 작업 창은 `Chrome.canvas` 단색을 직접 깐다.
struct WorkspaceCanvasSurface: View {
    let windowKind: WindowKind
    let isDark: Bool

    var body: some View {
        Color(nsColor: GlassSurfacePolicy.canvasColor(for: windowKind, isDark: isDark))
            .allowsHitTesting(false)
    }
}

/// 사이드바 한 겹만 `NSVisualEffectView.behindWindow`로 데스크톱을 샘플링한다.
/// 비활성 창에서는 followsWindowActiveState가 블러 합성 비용을 멈춘다.
final class BehindWindowGlassNSView: NSVisualEffectView {
    init(role: GlassSurfaceRole) {
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        isEmphasized = false
        configure(role: role)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(role: GlassSurfaceRole) {
        material = GlassSurfacePolicy.material(for: role)
    }
}

struct BehindWindowGlassSurface: NSViewRepresentable {
    let role: GlassSurfaceRole

    func makeNSView(context: Context) -> BehindWindowGlassNSView {
        BehindWindowGlassNSView(role: role)
    }

    func updateNSView(_ view: BehindWindowGlassNSView, context: Context) {
        view.configure(role: role)
    }
}
