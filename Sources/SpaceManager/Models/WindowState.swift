import Foundation

/// AppKit 전역 화면 좌표계의 창 프레임. CGRect를 저장 형식에 직접 노출하지 않아
/// 레거시 JSON 호환성과 테스트를 단순하게 유지한다.
struct WindowFrameState: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// 창 하나의 전체 상태(window-states.json).
/// 워크스페이스 목록은 전역 공유가 아니라 창별 소유 — 창마다 독립된 작업 세트.
/// 탭·패널은 여기 없다. 세션 층의 배치 파일이 원본이다.
struct WindowState: Codable, Identifiable {
    let id: UUID
    /// 옛 파일의 창 종류. "quick"(없앤 Quick 창)인 상태는 읽을 때 버린다(`WorkspaceStorage.loadWindowStates`).
    /// 문자열로 읽어야 모르는 값이 와도 파일 전체를 버리지 않는다.
    var kind: String? = nil
    var selectedWorkspaceId: UUID?
    var workspaces: [Workspace]? = nil   // nil이면 레거시(전역 목록) 상태 — 복원 시 1회 이관
    /// 창별 라이트/다크 선택 ("light"/"dark"/"system"). nil이면 레거시 — 전역 기본값 사용
    var appearance: String? = nil
    /// 확대/전체화면 전의 일반 창 프레임. nil이면 구 버전 상태다.
    var frame: WindowFrameState? = nil
    /// optional로 두어 필드가 없던 구 JSON도 별도 migration 없이 읽는다.
    var isZoomed: Bool? = nil
    var isFullscreen: Bool? = nil

    var isWorkspaceWindow: Bool { kind == nil || kind == "workspace" }
    var resolvedIsZoomed: Bool { isZoomed ?? false }
    var resolvedIsFullscreen: Bool { isFullscreen ?? false }
}
