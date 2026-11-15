import Foundation

/// Represents a single project (folder) in the workspace
struct Project: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var path: String
    var name: String

    init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Represents a workspace containing multiple projects
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var rootPath: String
    var customName: String?
    var additionalProjects: [Project]
    var createdAt: Date
    var updatedAt: Date
    /// 세션 층의 배치 이름(`~/.smux/state/sm/workspaces/<이름>.json`). nil이면 사이드바 이름에서 파생한다.
    var layoutName: String?
    /// ssh 호스트 별칭 (예: "arch"). 설정되면 이 워크스페이스의 배치와 세션은 그 기기에 있다. nil이면 이 맥.
    var remoteHost: String?
    /// 사이드바 폴더 아이콘 색(`FolderTint.rawValue`). nil이면 기본 회색.
    var folderColor: String?

    var isRemote: Bool {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !host.isEmpty
    }

    /// 원격 호스트에서의 작업 디렉토리. 로컬 홈 아래 경로는 원격 $HOME 기준 상대경로로 옮긴다
    /// (맥 /Users/x/proj → 아치 /home/x/proj). 홈 밖 경로는 그대로 절대경로.
    var remoteDirectory: RemoteShell.Directory {
        RemoteShell.directory(forLocalPath: rootPath)
    }

    /// A host switch changes the attachment, not the project files. Refuse a
    /// missing Mac checkout instead of silently starting a shell in the home directory.
    func executionLocationError(host: String?) -> String? {
        guard host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &directory), directory.boolValue else {
            return "이 Mac에 작업 폴더가 없습니다. 폴더를 먼저 복원하거나 복사해 주세요.\n\(rootPath)"
        }
        return nil
    }

    var name: String {
        customName ?? URL(fileURLWithPath: rootPath).lastPathComponent
    }

    var projects: [Project] {
        var all = [Project(path: rootPath)]
        all.append(contentsOf: additionalProjects)
        return all
    }

    /// 실제 배치 이름 — 정해 둔 값이 있으면 그것, 없으면 사이드바 이름에서 파생
    var effectiveLayoutName: String {
        if let custom = layoutName,
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return Self.sanitizeLayoutName(name)
    }

    /// 배치 이름에 쓰지 않는 `.` `:` 공백을 `-`로 바꾼다(tmux 세션 이름 시절 규칙 그대로 — 옛 이름이 같게 나온다).
    /// 빈 결과는 "workspace".
    static func sanitizeLayoutName(_ raw: String) -> String {
        let mapped = raw.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
            (ch == "." || ch == ":" || ch == " ") ? "-" : ch
        }
        let result = String(mapped)
        return result.isEmpty ? "workspace" : result
    }

    init(id: UUID = UUID(), rootPath: String, customName: String? = nil, additionalProjects: [Project] = [], layoutName: String? = nil, remoteHost: String? = nil) {
        self.id = id
        self.rootPath = rootPath
        self.customName = customName
        self.additionalProjects = additionalProjects
        self.layoutName = layoutName
        self.remoteHost = remoteHost
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, rootPath, customName, additionalProjects, createdAt, updatedAt, remoteHost, folderColor
        /// 옛 이름 그대로 저장한다(기존 window-states.json을 그대로 읽게).
        case layoutName = "tmuxSessionName"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        additionalProjects = try container.decodeIfPresent([Project].self, forKey: .additionalProjects) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        layoutName = try container.decodeIfPresent(String.self, forKey: .layoutName)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
        folderColor = try container.decodeIfPresent(String.self, forKey: .folderColor)
    }

    mutating func addProject(_ project: Project) {
        guard project.path != rootPath,
              !additionalProjects.contains(where: { $0.path == project.path }) else { return }
        additionalProjects.append(project)
        updatedAt = Date()
    }

    mutating func removeProject(id: UUID) {
        additionalProjects.removeAll { $0.id == id }
        updatedAt = Date()
    }

    mutating func rename(to newName: String?) {
        customName = newName?.isEmpty == true ? nil : newName
        updatedAt = Date()
    }

    static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.id == rhs.id
    }
}
