import Foundation

/// Handles persistence of workspaces to disk
class WorkspaceStorage: ObservableObject {
    static let shared = WorkspaceStorage()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 레거시 마이그레이션 입력 전용 (읽기 전용) — 워크스페이스의 실소유는 창별 WindowState.
    @Published var workspaces: [Workspace] = []
    @Published var windowStates: [WindowState] = []
    private var claimedWindowStateIds: Set<UUID> = []

    /// Base directory for storage
    private var storageDirectory: URL {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".space-manager")
    }

    /// Legacy directory for migration
    private var legacyStorageDirectory: URL {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".workspace-manager")
    }

    /// Path to workspaces file
    private var workspacesFile: URL {
        storageDirectory.appendingPathComponent("workspaces.json")
    }

    private var windowStatesFile: URL {
        storageDirectory.appendingPathComponent("window-states.json")
    }

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureStorageDirectoryExists()
        loadWorkspaces()
        loadWindowStates()
        // models.json·agent-states.json은 더 이상 로드하지 않는다 (파일은 남겨둠 — 롤백 안전)
    }

    private func ensureStorageDirectoryExists() {
        do {
            if fileManager.fileExists(atPath: legacyStorageDirectory.path),
               !fileManager.fileExists(atPath: storageDirectory.path) {
                try fileManager.moveItem(at: legacyStorageDirectory, to: storageDirectory)
            }
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        } catch {
            print("Warning: Could not create storage directory: \(error)")
        }
    }

    /// Load all workspaces from disk
    func loadWorkspaces() {
        guard fileManager.fileExists(atPath: workspacesFile.path) else {
            workspaces = []
            return
        }

        do {
            let data = try Data(contentsOf: workspacesFile)
            workspaces = try decoder.decode([Workspace].self, from: data)
        } catch {
            print("Error loading workspaces: \(error)")
            workspaces = []
        }
    }

    // MARK: - Window State Persistence

    func loadWindowStates() {
        guard fileManager.fileExists(atPath: windowStatesFile.path) else {
            windowStates = []
            return
        }
        do {
            let data = try Data(contentsOf: windowStatesFile)
            let decoded = try decoder.decode([WindowState].self, from: data)
            // Quick 창은 없앴다(11/15). 그 창의 상태는 복원할 것이 없으므로 버린다.
            windowStates = decoded.filter(\.isWorkspaceWindow)
            if windowStates.count != decoded.count { saveWindowStates() }
        } catch {
            print("Error loading window states: \(error)")
            windowStates = []
        }
    }

    func saveWindowStates() {
        do {
            let data = try encoder.encode(windowStates)
            try data.write(to: windowStatesFile, options: .atomic)
        } catch {
            print("Error saving window states: \(error)")
        }
    }

    /// scene에 보존된 ID로 자기 상태만 claim한다. 복원 창의 생성 순서와 무관하다.
    func claimWindowState(id: UUID) -> WindowState? {
        guard let state = Self.exactUnclaimedState(
            id: id,
            states: windowStates,
            claimedIDs: claimedWindowStateIds
        ) else { return nil }
        markClaimed(state.id)
        return state
    }

    /// 저장 배열 순서에 의존하지 않는 claim 핵심. 디스크를 건드리지 않고
    /// 창 정체성 회귀를 테스트할 수 있게 순수 함수로 둔다.
    static func exactUnclaimedState(
        id: UUID,
        states: [WindowState],
        claimedIDs: Set<UUID>
    ) -> WindowState? {
        guard !claimedIDs.contains(id) else { return nil }
        return states.first { $0.id == id }
    }

    /// scene value가 없던 구 버전 상태의 1회 migration 경로. 새 복원 경로는 ID claim만 쓴다.
    func claimNextWindowState() -> WindowState? {
        guard let state = windowStates.first(where: {
            !claimedWindowStateIds.contains($0.id)
                && !Self.isDiscardableEmptyWorkspaceState($0)
        }) else {
            return nil
        }
        markClaimed(state.id)
        return state
    }

    func registerClaimed(_ id: UUID) {
        markClaimed(id)
    }

    func containsWindowState(id: UUID) -> Bool {
        windowStates.contains { $0.id == id }
    }

    func unclaimedWindowStates() -> [WindowState] {
        windowStates.filter {
            !claimedWindowStateIds.contains($0.id)
                && !Self.isDiscardableEmptyWorkspaceState($0)
        }
    }

    /// An explicitly empty workspace window carries no durable user data. It
    /// should not multiply during macOS scene restoration; a fresh Cmd-N window
    /// remains available while the app is running.
    static func isDiscardableEmptyWorkspaceState(_ state: WindowState) -> Bool {
        state.workspaces?.isEmpty == true
    }

    var claimedCount: Int { claimedWindowStateIds.count }

    func updateWindowState(_ state: WindowState) {
        if let index = windowStates.firstIndex(where: { $0.id == state.id }) {
            windowStates[index] = state
        } else {
            windowStates.append(state)
        }
        saveWindowStates()
    }

    func removeWindowState(id: UUID) {
        claimedWindowStateIds.remove(id)
        windowStates.removeAll { $0.id == id }
        saveWindowStates()
    }

    private func markClaimed(_ id: UUID) {
        claimedWindowStateIds.insert(id)
    }
}
