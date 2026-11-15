import Foundation
import SwiftUI
import Combine

/// 창 하나의 상태: 그 창의 워크스페이스 목록과 고른 워크스페이스. 탭·패널은 세션 층의 배치 파일이 원본이고
/// (`LayoutDirectory`), 이 창은 그것을 그린다.
class AppState: ObservableObject {
    let storage = WorkspaceStorage.shared

    let windowStateId: UUID
    let shouldCloseOnAppearance: Bool

    /// NSWindow가 다시 붙을 때 적용할 일반 프레임과 표시 상태.
    private(set) var restoredWindowFrame: WindowFrameState?
    private(set) var restoredWindowIsZoomed = false
    private(set) var restoredWindowIsFullscreen = false

    /// 이 창이 소유한 워크스페이스 목록 (창별 독립 — 전역 공유 아님)
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspace: Workspace?
    @Published var selectedProject: Project?

    /// 배치 데이터가 있는 워크스페이스의 패널 터미널과 화면 쪽 상태.
    let layoutTerminals = LayoutTerminals()
    let layoutInteraction = LayoutInteraction()

    @Published var showNewWorkspaceSheet = false
    @Published var showAddProjectSheet = false

    /// 창별 라이트/다크 — 전역(NSApp)이 아니라 이 창의 NSWindow.appearance에 적용된다.
    /// 레거시 전역 선택(UserDefaults)을 새 창의 기본값으로 승계한다.
    @Published var preferredAppearance: String =
        UserDefaults.standard.string(forKey: "preferredAppearance") ?? "system"

    init(requestedWindowStateId: UUID? = nil) {
        // windowStateId(let)를 모든 분기에서 먼저 확정해야 한다 — self.storage 접근(구독 설정)은
        // 저장 프로퍼티가 전부 초기화된 뒤에만 허용되므로, claim 판단을 그보다 앞에 끝낸다.
        let sharedStorage = WorkspaceStorage.shared
        let discardRequestedState = requestedWindowStateId.flatMap { requestedID in
            sharedStorage.windowStates.first { $0.id == requestedID }
        }.map(WorkspaceStorage.isDiscardableEmptyWorkspaceState) ?? false
        shouldCloseOnAppearance = discardRequestedState
        if discardRequestedState, let requestedWindowStateId {
            sharedStorage.removeWindowState(id: requestedWindowStateId)
        }
        let claimed: WindowState?
        if let requestedWindowStateId, !discardRequestedState {
            claimed = sharedStorage.claimWindowState(id: requestedWindowStateId)
        } else {
            // scene value가 없던 구 버전/최초 기본 창만 순번 migration을 거친다.
            claimed = sharedStorage.claimNextWindowState()
        }
        if let claimed {
            windowStateId = claimed.id
        } else {
            // 같은 scene ID가 중복 생성돼 이미 claim된 경우 한 상태를 두 창이 공유하지 않는다.
            if let requestedWindowStateId,
               !sharedStorage.containsWindowState(id: requestedWindowStateId) {
                windowStateId = requestedWindowStateId
            } else {
                windowStateId = UUID()
            }
            sharedStorage.registerClaimed(windowStateId)
        }

        if let claimed {
            restore(from: claimed)
        } else if storage.windowStates.isEmpty && !storage.workspaces.isEmpty {
            // 업그레이드 경로: 창 상태가 하나도 없으면 레거시 전역 목록(workspaces.json)을
            // 첫 창으로 1회 이관한다. 이후 생성되는 새 창(Cmd+N)은 빈 목록으로 시작.
            workspaces = storage.workspaces
            if let first = workspaces.first {
                selectWorkspace(first)
            } else {
                persistWindowState()
            }
        }
        // 새 창은 빈 워크스페이스 목록으로 시작한다
        WorkspaceWindowRegistry.shared.register(self)
    }

    deinit {
        WorkspaceWindowRegistry.shared.unregister(self)
        // 창이 닫히면 그 창의 상태를 제거. 앱 종료 시에는 유지해야 하므로 가드
        // (macOS는 종료 시 deinit을 보장하지 않지만, 호출되는 경우를 방어)
        if !AppTermination.isTerminating {
            WorkspaceStorage.shared.removeWindowState(id: windowStateId)
        }
    }

    private func restore(from state: WindowState) {
        restoredWindowFrame = state.frame
        restoredWindowIsZoomed = state.resolvedIsZoomed
        restoredWindowIsFullscreen = state.resolvedIsFullscreen

        // 레거시 상태(workspaces 없음)는 전역 목록에서 1회 이관
        workspaces = state.workspaces ?? storage.workspaces
        if let appearance = state.appearance {
            preferredAppearance = appearance
        }
        if let wsId = state.selectedWorkspaceId,
           let workspace = workspaces.first(where: { $0.id == wsId }) {
            selectWorkspace(workspace)
        } else if let first = workspaces.first {
            selectWorkspace(first)
        }
    }

    func persistWindowState() {
        WorkspaceStorage.shared.updateWindowState(WindowState(
            id: windowStateId,
            selectedWorkspaceId: selectedWorkspace?.id,
            workspaces: workspaces,
            appearance: preferredAppearance,
            frame: restoredWindowFrame,
            isZoomed: restoredWindowIsZoomed,
            isFullscreen: restoredWindowIsFullscreen
        ))
    }

    /// 이동/리사이즈 알림에서 호출된다. 확대·전체화면 중에는 일반 프레임을 덮지 않는다.
    func updateWindowPresentation(
        frame: WindowFrameState?,
        isZoomed: Bool,
        isFullscreen: Bool
    ) {
        if let frame {
            restoredWindowFrame = frame
        }
        restoredWindowIsZoomed = isZoomed
        restoredWindowIsFullscreen = isFullscreen
        persistWindowState()
    }

    func setAppearance(_ raw: String) {
        preferredAppearance = raw
        persistWindowState()
    }

    // MARK: - Workspace Management

    /// `layoutName`: 세션 층 배치 이름에 묶는다(사이드바 이름을 바꿔도 같은 배치를 보이게).
    /// `select: false`: 에이전트가 만든 워크스페이스 — SEOL이 보던 워크스페이스를 바꾸지 않고 목록에만 넣는다.
    @discardableResult
    func createWorkspace(rootPath: String, customName: String? = nil, remoteHost: String? = nil,
                         layoutName: String? = nil, select: Bool = true) -> String? {
        let path = ((rootPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath as NSString).standardizingPath
        let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        var workspace = Workspace(rootPath: path, customName: customName, remoteHost: host?.isEmpty == false ? host : nil)
        if let layoutName, !layoutName.isEmpty { workspace.layoutName = layoutName }
        if let error = workspace.executionLocationError(host: workspace.remoteHost) { return error }
        workspaces.append(workspace)
        if select { selectWorkspace(workspace) } else { persistWindowState() }
        return nil
    }

    private func workspaceIndex(id: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String?) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        // 배치 이름은 사이드바 이름에서 나온다(따로 정하지 않았으면). 이름만 바꾸면 다른 배치를 찾아 화면이 비므로,
        // 지금 이름을 배치 이름으로 묶어 둔 뒤 바꾼다.
        if workspaces[index].layoutName?.isEmpty ?? true {
            workspaces[index].layoutName = workspaces[index].effectiveLayoutName
        }
        workspaces[index].rename(to: newName)
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = workspaces[index]
        }
        persistWindowState()
    }

    func setFolderColor(_ workspace: Workspace, to color: String?) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        workspaces[index].folderColor = color
        workspaces[index].updatedAt = Date()
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = workspaces[index]
        }
        persistWindowState()
    }

    func moveWorkspace(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < workspaces.count,
              destinationIndex >= 0, destinationIndex <= workspaces.count else { return }
        var updated = workspaces
        updated.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
        workspaces = updated
        persistWindowState()
    }

    /// 배치 이름을 정한다 — 이미 있는 배치(`sm ws ls`)에 이 사이드바 항목을 잇는 수단. 비우면 이름에서 파생한다.
    /// 앞 배치의 패널 터미널은 닫는다(세션은 계속 돈다).
    func setLayoutName(_ workspace: Workspace, to raw: String) {
        guard let index = workspaceIndex(id: workspace.id) else { return }
        layoutTerminals.discard(layoutKey: layoutKey(for: workspaces[index]))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].layoutName = trimmed.isEmpty ? nil : Workspace.sanitizeLayoutName(trimmed)
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = workspaces[index]
        }
        persistWindowState()
    }

    /// 실행 위치를 바꾼다. 배치와 세션은 기기마다 따로이므로, 화면은 그 기기의 같은 이름 배치를 그린다.
    /// 앞 기기의 패널 터미널은 닫는다(세션은 그 기기에서 계속 돈다).
    @discardableResult
    func setRemoteHost(_ workspace: Workspace, to raw: String) -> String? {
        guard let index = workspaceIndex(id: workspace.id) else { return "워크스페이스를 찾을 수 없습니다." }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmed.isEmpty ? nil : trimmed
        guard workspaces[index].remoteHost != host else { return nil }
        if let error = workspaces[index].executionLocationError(host: host) { return error }
        layoutTerminals.discard(layoutKey: layoutKey(for: workspaces[index]))
        workspaces[index].remoteHost = host
        workspaces[index].updatedAt = Date()
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = workspaces[index]
        }
        persistWindowState()
        return nil
    }

    /// 사이드바에서 뺀다. 배치와 세션은 세션 층에 그대로 남는다(`sm ws rm`이 배치를 지운다).
    func deleteWorkspace(_ workspace: Workspace) {
        layoutTerminals.discard(layoutKey: layoutKey(for: workspace))
        workspaces.removeAll { $0.id == workspace.id }
        if selectedWorkspace?.id == workspace.id {
            if let next = workspaces.first {
                selectWorkspace(next)
            } else {
                selectedWorkspace = nil
                selectedProject = nil
            }
        }
        persistWindowState()
    }

    /// 사이드바 항목을 다른 창으로 옮긴다. 배치와 세션은 세션 층에 그대로 있고, 칸은 받은 창이 고를 때 다시 붙는다.
    /// 받은 창의 화면은 그대로 둔다 — 비어 있던 창만 이것을 보여 준다.
    func transferWorkspace(_ workspace: Workspace, to target: AppState) {
        deleteWorkspace(workspace)
        target.workspaces.append(workspace)
        if target.selectedWorkspace == nil {
            target.selectWorkspace(workspace)
        } else {
            target.persistWindowState()
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        selectedProject = Project(path: workspace.rootPath, name: workspace.name)
        persistWindowState()
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard let selected = selectedWorkspace,
              let index = workspaceIndex(id: selected.id) else { return }
        workspaces[index].addProject(Project(path: path))
        selectedWorkspace = workspaces[index]
        persistWindowState()
    }

    func removeProject(_ project: Project) {
        guard let selected = selectedWorkspace,
              let index = workspaceIndex(id: selected.id) else { return }
        workspaces[index].removeProject(id: project.id)
        selectedWorkspace = workspaces[index]
        if selectedProject?.id == project.id {
            selectedProject = workspaces[index].projects.first
        }
        persistWindowState()
    }

    func selectProject(_ project: Project) {
        selectedProject = project
    }
}
