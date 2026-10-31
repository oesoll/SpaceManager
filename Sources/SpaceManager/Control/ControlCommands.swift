import AppKit
import Foundation

/// `sm` CLI 명령 라우터. UI가 할 수 있는 일은 전부 여기서도 할 수 있어야 한다 —
/// 새 UI 기능을 추가하면 같은 커밋에서 명령도 추가한다.
@MainActor
enum ControlCommands {
    static let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".space-manager/control.sock")

    static func handle(_ request: ControlRequest, completion: @escaping (ControlResponse) -> Void) {
        do {
            if let deferred = try dispatchAsync(request, completion: completion) {
                _ = deferred
                return
            }
            completion(.ok(try dispatch(request)))
        } catch let error as CommandError {
            completion(.error(error.message))
        } catch {
            completion(.error("\(error)"))
        }
    }

    struct CommandError: Error { let message: String }
    private static func fail(_ message: String) -> CommandError { CommandError(message: message) }

    // MARK: - 동기 명령

    private static func dispatch(_ r: ControlRequest) throws -> Any {
        switch r.command {
        case "ping":
            return ["pid": ProcessInfo.processInfo.processIdentifier, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev"]

        case "windows.list":
            return liveWindows().map(describe)

        case "window.focus":
            let entry = try window(r)
            focus(entry)
            return describe(entry)

        case "window.close":
            let entry = try window(r)
            guard let nsWindow = entry.window else { throw fail("window has no NSWindow yet") }
            nsWindow.performClose(nil)
            return ["closed": entry.state.windowStateId.uuidString]

        case "window.appearance":
            let entry = try window(r)
            guard let value = r.string("value"), ["light", "dark", "system"].contains(value) else {
                throw fail("value must be light|dark|system")
            }
            entry.state.setAppearance(value)
            return describe(entry)

        case "ws.list":
            let targets = r.string("window") == nil ? liveWindows().filter { $0.state.windowKind == .workspace } : [try window(r)]
            return targets.flatMap { entry in entry.state.workspaces.map { describe($0, in: entry) } }

        case "ws.add":
            let entry = try workspaceWindow(r)
            guard let path = r.string("path") else { throw fail("path required") }
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            var host = r.string("host") ?? ""
            if ["local", "none", "-"].contains(host) { host = "" }
            if let error = entry.state.createWorkspace(rootPath: (absolute as NSString).standardizingPath, customName: r.string("name"), remoteHost: host) { throw fail(error) }
            guard let ws = entry.state.selectedWorkspace else { throw fail("workspace not created") }
            return describe(ws, in: entry)

        case "ws.rename":
            let (entry, ws) = try workspace(r)
            entry.state.renameWorkspace(ws, to: r.string("name"))
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.delete":
            let (entry, ws) = try workspace(r)
            entry.state.deleteWorkspace(ws)
            return ["deleted": ws.id.uuidString]

        case "ws.select":
            let (entry, ws) = try workspace(r)
            entry.state.selectWorkspace(ws)
            if r.bool("focus") ?? true { focus(entry) }
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.tmuxName":
            let (entry, ws) = try workspace(r)
            entry.state.setTmuxSessionName(ws, to: r.string("name") ?? "")
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.remote":
            let (entry, ws) = try workspace(r)
            var host = r.string("host") ?? ""
            if host == "none" || host == "local" || host == "-" { host = "" }
            if let error = entry.state.setRemoteHost(ws, to: host) { throw fail(error) }
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.move":
            let (entry, ws) = try workspace(r)
            guard let to = r.int("index"), let from = entry.state.workspaces.firstIndex(where: { $0.id == ws.id }) else {
                throw fail("index required")
            }
            entry.state.moveWorkspace(from: from, to: to > from ? to + 1 : to)
            return entry.state.workspaces.map { describe($0, in: entry) }

        case "project.add":
            let (entry, ws) = try workspace(r)
            guard let path = r.string("path") else { throw fail("path required") }
            entry.state.selectWorkspace(ws)
            entry.state.addProject(path: ((path as NSString).expandingTildeInPath as NSString).standardizingPath)
            return describe(try refetch(ws, in: entry), in: entry)

        case "project.remove":
            let (entry, ws) = try workspace(r)
            guard let path = r.string("path") else { throw fail("path required") }
            let target = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard let project = ws.additionalProjects.first(where: { $0.path == target || $0.name == path }) else {
                throw fail("project not found: \(path)")
            }
            entry.state.selectWorkspace(ws)
            entry.state.removeProject(project)
            return describe(try refetch(ws, in: entry), in: entry)

        case "tab.list":
            let (entry, ws) = try workspaceOrSelected(r)
            return entry.state.sessions(for: ws).map { describe($0, selected: entry.state.selectedSession?.id == $0.id) }

        case "tab.shell", "tab.tmux":
            let (entry, ws) = try workspaceOrSelected(r)
            entry.state.selectWorkspace(ws)
            if r.command == "tab.shell" { entry.state.addShellTab() } else { entry.state.addTmuxTab() }
            guard let session = entry.state.selectedSession else { throw fail("tab not created") }
            return describe(session, selected: true)

        case "tab.select", "tab.close", "tab.reconnect":
            let (entry, workspace, session) = try tab(r)
            if r.command == "tab.reconnect" {
                session.reconnectIfNeeded()
                return describe(session, selected: entry.state.selectedSession?.id == session.id)
            }
            if r.command == "tab.select" {
                // 다른 워크스페이스의 탭이면 그 워크스페이스로 먼저 옮긴다 (같은 세션 객체가 복원된다).
                if let workspace, entry.state.selectedWorkspace?.id != workspace.id {
                    entry.state.selectWorkspace(workspace)
                }
                entry.state.selectSession(session)
                if r.bool("focus") ?? true { focus(entry) }
                return describe(session, selected: true)
            }
            guard session.kind != .tmuxMain else { throw fail("main tmux tab cannot be closed (it is recreated on next visit)") }
            entry.state.removeSession(session)
            return ["closed": session.id.uuidString]

        case "tab.next", "tab.prev":
            let entry = try window(r)
            if r.command == "tab.next" { entry.state.selectNextSession() } else { entry.state.selectPreviousSession() }
            guard let session = entry.state.selectedSession else { throw fail("no tabs") }
            return describe(session, selected: true)

        case "quick.list":
            let limit = r.int("limit") ?? 30
            let dir = QuickConversationScanner.defaultTranscriptsDirectory()
            let titles = QuickConversationScanner.scanAITitles(directory: dir)
            return QuickConversationScanner.scan(directory: dir).prefix(limit).map { c in
                ["id": c.id, "title": titles[c.id] ?? c.aiTitle ?? c.title, "modifiedAt": iso(c.modifiedAt), "transcript": c.transcriptURL.path]
            }

        case "quick.home":
            let entry = try quickWindow(r)
            entry.state.showQuickHome()
            return describe(entry)

        case "activity.list":
            let scanner = RecentActivityScanner.shared
            return [
                "sessions": scanner.sessions.map {
                    ["id": $0.id, "provider": $0.provider.rawValue, "cwd": $0.cwd, "name": $0.name,
                     "lastActivity": iso($0.lastActivity), "snippet": $0.snippet ?? "", "host": $0.host ?? ""]
                },
                "workspaceActivity": scanner.workspaceActivity.mapValues(iso),
                "generating": Array(scanner.generatingDirectories).sorted(),
            ]

        case "state.dump":
            let data = try JSONEncoder.pretty.encode(WorkspaceStorage.shared.windowStates)
            return try JSONSerialization.jsonObject(with: data)

        case "quick.new", "quick.resume", "window.new", "window.capture", "perf.frames", "session.reveal":
            throw fail("internal: async command reached sync dispatcher")
        default:
            throw fail("unknown command: \(r.command)")
        }
    }

    // MARK: - 비동기 명령 (창을 열고 기다려야 하는 것들)

    /// 처리했으면 non-nil. 창 생성은 SwiftUI가 다음 run loop에서 AppState를 만들기 때문에
    /// 레지스트리에 새 창이 등록될 때까지 폴링한 뒤 응답한다.
    private static func dispatchAsync(_ r: ControlRequest, completion: @escaping (ControlResponse) -> Void) throws -> Bool? {
        switch r.command {
        case "window.new":
            let kind: WindowKind = (r.string("kind") ?? "workspace") == "quick" ? .quick : .workspace
            openWindow(kind: kind) { result in
                completion(result.map { .ok(describe($0)) } ?? .error("window did not appear"))
            }
            return true

        case "window.capture":
            let entry = try window(r)
            guard let nsWindow = entry.window else { throw fail("window has no NSWindow yet") }
            var rect: CGRect?
            if let spec = r.string("rect") {
                let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4 else { throw fail("rect must be x,y,w,h (points from the window's top-left)") }
                rect = WindowProbe.screenRect(CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]), in: nsWindow)
            }
            let count = r.int("burst") ?? 1
            if count > 1 {
                guard let rect else { throw fail("--burst needs --rect (a small area keeps the shots fast)") }
                let every = Double(r.int("every") ?? 8) / 1000
                WindowProbe.burst(windowNumber: nsWindow.windowNumber, screenRect: rect, count: min(count, 600),
                                  every: every, folder: r.string("path")) { rows in
                    completion(.ok(["frames": rows]))
                }
                return true
            }
            guard let path = r.string("path") else { throw fail("path required") }
            guard let image = WindowProbe.image(windowNumber: nsWindow.windowNumber, screenRect: rect) else {
                throw fail("capture failed (window off screen or minimized?)")
            }
            try WindowProbe.writePNG(image, to: path)
            completion(.ok(["path": path, "width": image.width, "height": image.height,
                            "scale": nsWindow.backingScaleFactor]))
            return true

        case "session.reveal":
            guard let target = r.string("target"), !target.isEmpty else { throw fail("usage: sm reveal NAME[@HOST]") }
            // 어디 있는지는 세션 층이 안다(원격도, 이름의 대소문자도 맞춰 준다).
            SessionLayer.run(["where", target, "--json"]) { result in
                switch result {
                case .failure(let failure):
                    completion(.error(failure.message))
                case .success(let data):
                    guard let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = found["name"] as? String, let host = found["host"] as? String else {
                        completion(.error("sm-session where: unexpected answer")); return
                    }
                    guard let layoutWorkspace = found["workspace"] as? String else {
                        completion(.error("\(name)@\(host) is not in any workspace")); return
                    }
                    let key = LayoutDirectory.key(workspace: layoutWorkspace, host: host)
                    // 그 워크스페이스를 이미 보여 주는 창 → 앞에 있는 창 → 그 워크스페이스를 가진 아무 창.
                    let windows = liveWindows().filter { $0.state.windowKind == .workspace }
                    let holding = windows.compactMap { entry in
                        entry.state.workspaces.first { entry.state.layoutKey(for: $0) == key }.map { (entry, $0) }
                    }
                    let chosen = holding.first { $0.0.state.selectedWorkspace?.id == $0.1.id }
                        ?? holding.first { $0.0.window?.isKeyWindow == true } ?? holding.first
                    guard let (entry, workspace) = chosen else {
                        completion(.error("no sm window has workspace \(key) — add it with sm ws add")); return
                    }
                    focus(entry)
                    entry.state.reveal(session: name, in: workspace, layoutKey: key, pane: found["pane"] as? String) { outcome in
                        switch outcome {
                        case .failure(let failure): completion(.error(failure.message))
                        case .success(let place):
                            completion(.ok(["name": name, "host": host, "workspace": layoutWorkspace, "tab": place.tab,
                                            "pane": place.pane, "window": entry.state.windowStateId.uuidString]))
                        }
                    }
                }
            }
            return true

        case "perf.frames":
            let entry = try window(r)
            guard let nsWindow = entry.window else { throw fail("window has no NSWindow yet") }
            let seconds = min(max(Double(r.string("seconds") ?? "3") ?? 3, 0.2), 60)
            let action = try r.string("do").map { try probeAction($0, state: entry.state) }
            var watch: CGRect?
            if let spec = r.string("rect") {
                let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4 else { throw fail("rect must be x,y,w,h (points from the window's top-left)") }
                watch = WindowProbe.screenRect(CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]), in: nsWindow)
            }
            FrameProbe.run(window: nsWindow, seconds: seconds, action: action, watch: watch) { completion(.ok($0)) }
            return true

        case "quick.new", "quick.resume":
            let configuration = try quickConfiguration(r)
            let run: (WindowEntry) -> Void = { entry in
                if r.command == "quick.resume" {
                    guard let id = r.string("id") else { completion(.error("id required")); return }
                    entry.state.resumeQuickConversation(sessionId: id)
                } else {
                    entry.state.addQuickSession(initialPrompt: r.string("prompt"), configuration: configuration)
                }
                if r.bool("focus") ?? true { focus(entry) }
                guard let session = entry.state.selectedSession else { completion(.error("session not created")); return }
                completion(.ok(describe(session, selected: true)))
            }
            if let entry = try? quickWindow(r) {
                run(entry)
            } else {
                openWindow(kind: .quick) { entry in
                    guard let entry else { completion(.error("could not open quick window")); return }
                    run(entry)
                }
            }
            return true
        default:
            return nil
        }
    }

    /// `sm perf --do`: 사람이 누르는 것과 같은 길(⌘숫자, ⌥⌘←→, ⌘[ ⌘], 사이드바 클릭)로 한 번 움직인다.
    private static func probeAction(_ spec: String, state: AppState) throws -> () -> Void {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? "", value = parts.count > 1 ? parts[1] : ""
        switch (verb, value) {
        case ("tab", "next"): return { state.stepTab(forward: true) }
        case ("tab", "prev"): return { state.stepTab(forward: false) }
        case ("tab", _):
            guard let number = Int(value), number >= 1 else { throw fail("tab:N (1부터) | tab:next | tab:prev") }
            return { state.selectTab(at: number - 1) }
        case ("focus", "next"): return { state.cyclePane(forward: true) }
        case ("focus", "prev"): return { state.cyclePane(forward: false) }
        case ("ws", _):
            guard let workspace = state.workspaces.first(where: { $0.name == value || $0.tmuxSessionName == value }) else {
                throw fail("no workspace named \(value) in this window")
            }
            return { state.selectWorkspace(workspace) }
        default:
            throw fail("--do takes tab:N | tab:next | tab:prev | focus:next | focus:prev | ws:NAME")
        }
    }

    private static func openWindow(kind: WindowKind, completion: @escaping (WindowEntry?) -> Void) {
        guard let open = WindowOpener.open else { completion(nil); return }
        let before = Set(liveWindows().map { $0.state.windowStateId })
        let id = UUID()
        open(kind.sceneID, id)
        NSApp.activate(ignoringOtherApps: true)
        var attempts = 0
        func poll() {
            if let entry = liveWindows().first(where: { $0.state.windowStateId == id || (!before.contains($0.state.windowStateId) && $0.state.windowKind == kind) }) {
                completion(entry); return
            }
            attempts += 1
            if attempts > 40 { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private static func quickConfiguration(_ r: ControlRequest) throws -> QuickSessionConfiguration {
        let base = QuickComposerPreferences.load()
        var effort = base.effort
        if let raw = r.string("effort") {
            guard let parsed = QuickEffort(rawValue: raw) else {
                throw fail("effort must be one of \(QuickEffort.allCases.map(\.rawValue).joined(separator: "|"))")
            }
            effort = parsed
        }
        return QuickSessionConfiguration(
            modelID: r.string("model") ?? base.modelID,
            effort: effort,
            proxyEnabled: r.bool("proxy") ?? base.proxyEnabled
        )
    }

    // MARK: - 대상 해석

    typealias WindowEntry = (state: AppState, window: NSWindow?)

    static func liveWindows() -> [WindowEntry] {
        WorkspaceWindowRegistry.shared.liveEntries()
    }

    private static func window(_ r: ControlRequest) throws -> WindowEntry {
        let entries = liveWindows()
        guard !entries.isEmpty else { throw fail("no windows open") }
        guard let query = r.string("window"), !query.isEmpty, query != "front", query != "key" else {
            return entries.first { $0.window?.isKeyWindow == true } ?? entries.first { $0.window != nil } ?? entries[0]
        }
        if let index = Int(query), entries.indices.contains(index) { return entries[index] }
        if let hit = entries.first(where: { $0.state.windowStateId.uuidString.lowercased().hasPrefix(query.lowercased()) }) { return hit }
        if let hit = entries.first(where: { $0.state.windowKind.rawValue == query.lowercased() }) { return hit }
        throw fail("window not found: \(query)")
    }

    private static func workspaceWindow(_ r: ControlRequest) throws -> WindowEntry {
        let entry = try window(r)
        if entry.state.windowKind == .workspace { return entry }
        guard let other = liveWindows().first(where: { $0.state.windowKind == .workspace }) else {
            throw fail("no workspace window open (sm window new)")
        }
        return other
    }

    private static func quickWindow(_ r: ControlRequest) throws -> WindowEntry {
        if let query = r.string("window"), !query.isEmpty, query != "front", query != "key" {
            let entry = try window(r)
            guard entry.state.windowKind == .quick else { throw fail("window \(query) is not a quick window") }
            return entry
        }
        let quicks = liveWindows().filter { $0.state.windowKind == .quick }
        guard let entry = quicks.first(where: { $0.window?.isKeyWindow == true }) ?? quicks.first else {
            throw fail("no quick window open")
        }
        return entry
    }

    /// 워크스페이스 질의: id 접두사 / 이름 / tmux 세션명 / 경로 / 경로 마지막 요소.
    static func matchWorkspace(_ query: String, in workspaces: [Workspace]) -> Workspace? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        let expanded = ((q as NSString).expandingTildeInPath as NSString).standardizingPath
        return workspaces.first { $0.id.uuidString.lowercased() == lower }
            ?? workspaces.first { $0.name == q }
            ?? workspaces.first { $0.effectiveTmuxSessionName == q }
            ?? workspaces.first { $0.rootPath == expanded }
            ?? workspaces.first { $0.name.lowercased() == lower }
            ?? workspaces.first { ($0.rootPath as NSString).lastPathComponent.lowercased() == lower }
            ?? (q.count >= 4 ? workspaces.first { $0.id.uuidString.lowercased().hasPrefix(lower) } : nil)
    }

    private static func workspace(_ r: ControlRequest) throws -> (WindowEntry, Workspace) {
        guard let query = r.string("ws") else { throw fail("workspace required") }
        let candidates: [WindowEntry] = r.string("window") == nil
            ? liveWindows().filter { $0.state.windowKind == .workspace }
            : [try window(r)]
        for entry in candidates {
            if let ws = matchWorkspace(query, in: entry.state.workspaces) { return (entry, ws) }
        }
        throw fail("workspace not found: \(query)")
    }

    private static func workspaceOrSelected(_ r: ControlRequest) throws -> (WindowEntry, Workspace) {
        if r.string("ws") != nil { return try workspace(r) }
        let entry = try workspaceWindow(r)
        guard let ws = entry.state.selectedWorkspace else { throw fail("no workspace selected") }
        return (entry, ws)
    }

    private static func refetch(_ ws: Workspace, in entry: WindowEntry) throws -> Workspace {
        guard let fresh = entry.state.workspaces.first(where: { $0.id == ws.id }) else { throw fail("workspace vanished") }
        return fresh
    }

    /// 탭 질의 대상. `sm tabs <ws>`는 선택되지 않은 워크스페이스의 탭도 보여 주므로,
    /// 거기서 얻은 ID·이름은 화면 선택과 무관하게 찾아져야 한다.
    private static func tab(_ r: ControlRequest) throws -> (WindowEntry, Workspace?, TerminalSession) {
        guard let query = r.string("tab") else { throw fail("tab required") }
        var groups: [(entry: WindowEntry, workspace: Workspace?, sessions: [TerminalSession])] = []
        if r.string("ws") != nil {
            let (entry, ws) = try workspace(r)
            groups = [(entry, ws, entry.state.sessions(for: ws))]
        } else {
            // 첫 그룹 = 대상 창(기본 key 창)의 보이는 탭 목록. 인덱스는 이 목록 기준이다.
            let front = try window(r)
            let others = r.string("window") == nil ? liveWindows().filter { $0.state !== front.state } : []
            for entry in [front] + others {
                let selectedID = entry.state.selectedWorkspace?.id
                groups.append((entry, entry.state.selectedWorkspace, entry.state.sessions))
                for ws in entry.state.workspaces where ws.id != selectedID {
                    groups.append((entry, ws, entry.state.sessions(for: ws)))
                }
            }
        }
        guard let hit = matchTab(query, in: groups.map(\.sessions)) else { throw fail("tab not found: \(query)") }
        let group = groups[hit.group]
        return (group.entry, group.workspace, hit.session)
    }

    /// 우선순위: 정확한 id → 이름/tmux 세션명 → 인덱스(첫 그룹만) → id 접두사(4자 이상).
    /// 각 단계는 그룹 순서대로 훑으므로 같은 이름이면 보이는 탭이 이긴다.
    nonisolated static func matchTab(_ query: String, in groups: [[TerminalSession]]) -> (group: Int, session: TerminalSession)? {
        let lower = query.lowercased()
        func first(_ match: (TerminalSession) -> Bool) -> (group: Int, session: TerminalSession)? {
            for (index, sessions) in groups.enumerated() {
                if let hit = sessions.first(where: match) { return (index, hit) }
            }
            return nil
        }
        if let hit = first({ $0.id.uuidString.lowercased() == lower }) { return hit }
        if let hit = first({ $0.name == query || $0.tmuxSessionName == query }) { return hit }
        if let index = Int(query), let visible = groups.first, visible.indices.contains(index) {
            return (0, visible[index])
        }
        guard query.count >= 4 else { return nil }
        return first { $0.id.uuidString.lowercased().hasPrefix(lower) }
    }

    private static func focus(_ entry: WindowEntry) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = entry.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 직렬화

    private static func describe(_ entry: WindowEntry) -> [String: Any] {
        [
            "id": entry.state.windowStateId.uuidString,
            "kind": entry.state.windowKind.rawValue,
            "isKey": entry.window?.isKeyWindow ?? false,
            "appearance": entry.state.preferredAppearance,
            "workspaceCount": entry.state.workspaces.count,
            "selectedWorkspace": entry.state.selectedWorkspace?.name ?? "",
            "tabCount": entry.state.sessions.count,
        ]
    }

    private static func describe(_ ws: Workspace, in entry: WindowEntry) -> [String: Any] {
        [
            "id": ws.id.uuidString,
            "name": ws.name,
            "rootPath": ws.rootPath,
            "tmuxSession": ws.effectiveTmuxSessionName,
            "customTmuxSession": ws.tmuxSessionName ?? "",
            "remoteHost": ws.remoteHost ?? "",
            "projects": ws.additionalProjects.map(\.path),
            "selected": entry.state.selectedWorkspace?.id == ws.id,
            "window": entry.state.windowStateId.uuidString,
        ]
    }

    private static func describe(_ s: TerminalSession, selected: Bool) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "kind": s.kind.rawValue,
            "name": s.name,
            "workingDirectory": s.workingDirectory,
            "tmuxSession": s.tmuxSessionName ?? "",
            "remoteHost": s.remoteHost ?? "",
            "running": s.isRunning,
            "reconnecting": s.isReconnecting,
            "error": s.startError ?? "",
            "lastConnectionFailure": s.lastConnectionFailure ?? "",
            "selected": selected,
        ]
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
}
