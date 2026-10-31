import Foundation

/// 워크스페이스 배치를 읽어 둔다. 모든 창이 같은 것을 보므로 하나만 돈다.
///
/// - 이 맥의 워크스페이스: 세션 층의 폴더(`~/.smux/state/sm/workspaces`)를 FSEvents로 지켜보고 JSON을
///   직접 읽는다. 프로세스를 띄우지 않는다. 읽기만 한다 — 쓰기는 언제나 `sm-session` 명령이다.
/// - 원격 워크스페이스: 화면에 보이는 것만 `sm-session watch --ws WS@HOST --json` 하나씩 붙들고,
///   배치가 바뀔 때마다 오는 한 줄을 읽는다(ssh 하나).
final class LayoutDirectory: ObservableObject {
    static let shared = LayoutDirectory()

    /// "워크스페이스@기기" → 배치.
    @Published private(set) var layouts: [String: WorkspaceLayout] = [:]

    private let folder: URL
    private let watcher = DirectoryWatcher()
    private let queue = DispatchQueue(label: "SpaceManager.LayoutDirectory", qos: .userInitiated)
    private var owners = Set<UUID>()
    private var followers: [String: RemoteFollower] = [:]
    /// 창별로 지금 보고 싶은 원격 워크스페이스.
    private var wantedRemote: [UUID: Set<String>] = [:]

    init(folder: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.smux/state/sm/workspaces")) {
        self.folder = folder
    }

    static func key(workspace: String, host: String) -> String { workspace + "@" + host }

    func layout(workspace: String, host: String) -> WorkspaceLayout? {
        layouts[Self.key(workspace: workspace, host: host)]
    }

    func start(owner: UUID) {
        let first = owners.isEmpty
        owners.insert(owner)
        guard first else { return }
        watcher.onChange = { [weak self] in self?.reloadLocal() }
        watcher.start(path: folder.path)
        reloadLocal()
    }

    func stop(owner: UUID) {
        owners.remove(owner)
        wantedRemote[owner] = nil
        updateFollowers()
        guard owners.isEmpty else { return }
        watcher.stop()
    }

    /// 이 창이 보여 줄 원격 워크스페이스(없으면 빈 집합). 아무 창도 원하지 않으면 그 ssh를 닫는다.
    func setRemote(_ keys: Set<String>, owner: UUID) {
        wantedRemote[owner] = keys
        updateFollowers()
    }

    /// 명령을 부른 직후 결과를 기다리지 않고 다시 읽는다(로컬). 원격은 watch가 곧 보낸다.
    func reloadLocal() {
        let folder = folder
        queue.async { [weak self] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var found: [String: WorkspaceLayout] = [:]
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let layout = try? WorkspaceLayout.decode(data) else { continue }
                found[Self.key(workspace: layout.workspace, host: layout.host)] = layout
            }
            DispatchQueue.main.async { self?.mergeLocal(found) }
        }
    }

    private var localKeys = Set<String>()

    private func mergeLocal(_ found: [String: WorkspaceLayout]) {
        var next = layouts
        for key in localKeys where found[key] == nil { next[key] = nil }
        for (key, layout) in found where next[key]?.version != layout.version || next[key] != layout {
            next[key] = layout
        }
        localKeys = Set(found.keys)
        if next != layouts { layouts = next }
    }

    fileprivate func receiveRemote(_ layout: WorkspaceLayout) {
        let key = Self.key(workspace: layout.workspace, host: layout.host)
        guard layouts[key] != layout else { return }
        layouts[key] = layout
    }

    private func updateFollowers() {
        let wanted = wantedRemote.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (key, follower) in followers where !wanted.contains(key) {
            follower.stop()
            followers[key] = nil
        }
        for key in wanted where followers[key] == nil {
            let follower = RemoteFollower(key: key) { [weak self] layout in self?.receiveRemote(layout) }
            followers[key] = follower
            follower.start()
        }
    }
}

/// 원격 워크스페이스 하나의 `sm-session watch` 스트림. 끊기면 잠시 뒤 다시 붙는다(기기가 잠든 동안 등).
private final class RemoteFollower {
    let key: String
    private let onLayout: (WorkspaceLayout) -> Void
    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var retry = 0

    init(key: String, onLayout: @escaping (WorkspaceLayout) -> Void) {
        self.key = key
        self.onLayout = onLayout
    }

    func start() {
        guard !stopped, FileManager.default.isExecutableFile(atPath: SessionLayer.executable) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SessionLayer.executable)
        process.arguments = ["watch", "--ws", key, "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([NSHomeDirectory() + "/.smux/bin", "/opt/homebrew/bin", "/usr/local/bin"]
                       + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRestart() }
        }
        do { try process.run() } catch { scheduleRestart(); return }
        self.process = process
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let layout = try? WorkspaceLayout.decode(Data(line)) {
                retry = 0
                onLayout(layout)
            }
        }
    }

    private func scheduleRestart() {
        process = nil
        guard !stopped else { return }
        retry += 1
        let delay = min(30, 2 * pow(2, Double(min(retry, 4))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }
}
