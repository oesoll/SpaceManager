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
            let targets = r.string("window") == nil ? liveWindows() : [try window(r)]
            return targets.flatMap { entry in entry.state.workspaces.map { describe($0, in: entry) } }

        case "ws.add":
            let entry = try workspaceWindow(r)
            guard let path = r.string("path") else { throw fail("path required") }
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            var host = r.string("host") ?? ""
            if ["local", "none", "-"].contains(host) { host = "" }
            let select = r.bool("select") ?? true
            let layoutName = r.string("layout")
            // 같은 배치를 이미 보여 주는 워크스페이스가 있으면 하나 더 만들지 않는다(에이전트가 두 번 불러도 그대로).
            if let layoutName, let existing = liveWindows().lazy.compactMap({ entry in
                entry.state.workspaces.first { $0.effectiveLayoutName == layoutName && ($0.remoteHost ?? "") == host }
                    .map { (entry, $0) }
            }).first {
                return describe(existing.1, in: existing.0).merging(["existed": true]) { $1 }
            }
            if let error = entry.state.createWorkspace(rootPath: (absolute as NSString).standardizingPath, customName: r.string("name"),
                                                       remoteHost: host, layoutName: layoutName, select: select) { throw fail(error) }
            guard let ws = select ? entry.state.selectedWorkspace : entry.state.workspaces.last else { throw fail("workspace not created") }
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

        case "ws.layoutName", "ws.tmuxName":
            let (entry, ws) = try workspace(r)
            entry.state.setLayoutName(ws, to: r.string("name") ?? "")
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

        case "ws.transfer":
            let (entry, ws) = try workspace(r)
            guard let to = r.string("to"), !to.isEmpty else { throw fail("to required") }
            let target = try window(query: to)
            if target.state !== entry.state { entry.state.transferWorkspace(ws, to: target.state) }
            return describe(ws, in: target)

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

        case "app.hide":
            NSApp.hide(nil)
            return ["hidden": true]
        case "app.show":
            StatusBarToggle.shared.show()
            return ["hidden": false]   // 숨김 풀기는 다음 차례에 반영된다 — 지금 isHidden은 아직 true다
        case "app.toggle":
            // 메뉴 막대 아이콘을 누른 것과 같다.
            StatusBarToggle.shared.toggle()
            return ["hidden": NSApp.isHidden]

        case "state.dump":
            let data = try JSONEncoder.pretty.encode(WorkspaceStorage.shared.windowStates)
            return try JSONSerialization.jsonObject(with: data)

        case "window.new", "window.capture", "perf.frames", "perf.keys", "session.reveal":
            throw fail("internal: async command reached sync dispatcher")
        default:
            throw fail("unknown command: \(r.command)")
        }
    }

    /// `sm to-fine NAME[@HOST]`: 그 세션을 보이는 sm 패널을 Fine으로 옮긴다(패널 메뉴 "Fine으로 옮기기"와 같다).
    private static func moveToFine(_ target: String, completion: @escaping (ControlResponse) -> Void) {
        SessionLayer.run(["where", target, "--json"]) { result in
            guard case .success(let data) = result,
                  let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = found["host"] as? String, let workspace = found["workspace"] as? String,
                  let pane = found["pane"] as? String else {
                completion(.error("\(target) is not shown in any sm pane")); return
            }
            let key = LayoutDirectory.key(workspace: workspace, host: host)
            guard let layout = LayoutDirectory.shared.layouts[key],
                  let entry = liveWindows().first(where: { entry in
                      entry.state.workspaces.contains { entry.state.layoutKey(for: $0) == key }
                  }) else { completion(.error("no sm window shows workspace \(key)")); return }
            entry.state.moveLayoutPaneToFine(pane, in: layout) { failure in
                if let failure { completion(.error(failure)) }
                else { completion(.ok(["moved": target, "pane": pane, "workspace": workspace])) }
            }
        }
    }

    /// `sm show` from an agent in a Fine tab: a session no screen shows yet opens as a Fine tab under the caller's,
    /// so a successor lands where its predecessor was. One an sm pane already shows still comes forward in sm.
    private static func revealBeside(fineTab: String, _ target: String, focus wantsFocus: Bool,
                                     completion: @escaping (ControlResponse) -> Void) {
        SessionLayer.run(["where", target, "--json"]) { result in
            let found = (try? result.get()).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let name = found?["name"] as? String ?? target, host = found?["host"] as? String
            let inPane = found?["pane"] is String || LayoutDirectory.shared.layouts.values.contains { layout in
                layout.panes.keys.contains { pane in
                    guard let agent = layout.agent(inPane: pane) else { return false }
                    return agent.name == name && (host == nil || agent.host == host)
                }
            }
            guard !inPane, found != nil else { return revealInSM(target, focus: wantsFocus, completion: completion) }
            FineControl.request("tab.attach", ["name": target, "parent": fineTab, "focus": wantsFocus]) { reply in
                switch reply {
                case .ok(let row): completion(.ok(["name": target, "fineTab": (row as? [String: Any])?["id"] ?? NSNull()]))
                case .failed(let message): completion(.error(message))
                case .unreachable: revealInSM(target, focus: wantsFocus, completion: completion)
                }
            }
        }
    }

    /// sm 패널에서 세션을 연다. 어디 있는지는 세션 층이 안다(원격도, 이름의 대소문자도 맞춰 준다).
    /// `focus`: also bring sm to the front and take the keyboard. Off when an agent asks (`sm show` from an agent's
    /// shell): the pane comes forward inside its window, but SEOL's current app and typing stay (11/06 SEOL "화면
    /// 포커스를 가로채는게 별로야"). A notch click and SEOL's own `sm show` keep it on.
    private static func revealInSM(_ target: String, focus wantsFocus: Bool = true, completion: @escaping (ControlResponse) -> Void) {
        SessionLayer.run(["where", target, "--json"]) { result in
            switch result {
            case .failure(let failure):
                completion(.error(failure.message))
            case .success(let data):
                guard let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = found["name"] as? String, let host = found["host"] as? String else {
                    completion(.error("sm-session where: unexpected answer")); return
                }
                // 세션 층은 자기 기기의 배치만 안다. 다른 기기 워크스페이스에 `NAME@HOST`로 넣은 칸은 앱이 아는 배치에서 찾는다.
                let elsewhere = LayoutDirectory.shared.layouts.values.lazy.compactMap { layout in
                    layout.panes.keys.first { pane in
                        guard let agent = layout.agent(inPane: pane) else { return false }
                        return agent.name == name && agent.host == host
                    }.map { (layout: layout, pane: $0) }
                }.first
                guard let layoutWorkspace = (found["workspace"] as? String) ?? elsewhere?.layout.workspace else {
                    completion(.error("\(name)@\(host) is not in any workspace")); return
                }
                let onOwner = found["workspace"] is String
                let key = LayoutDirectory.key(workspace: layoutWorkspace, host: onOwner ? host : elsewhere?.layout.host ?? host)
                // 그 워크스페이스를 이미 보여 주는 창 → 앞에 있는 창 → 그 워크스페이스를 가진 아무 창.
                let windows = liveWindows()
                let holding = windows.compactMap { entry in
                    entry.state.workspaces.first { entry.state.layoutKey(for: $0) == key }.map { (entry, $0) }
                }
                let chosen = holding.first { $0.0.state.selectedWorkspace?.id == $0.1.id }
                    ?? holding.first { $0.0.window?.isKeyWindow == true } ?? holding.first
                guard let (entry, workspace) = chosen else {
                    completion(.error("no sm window has workspace \(key) — add it with sm ws add")); return
                }
                if wantsFocus { focus(entry) }
                entry.state.reveal(session: name, in: workspace, layoutKey: key,
                                   pane: found["pane"] as? String ?? (onOwner ? nil : elsewhere?.pane)) { outcome in
                    switch outcome {
                    case .failure(let failure): completion(.error(failure.message))
                    case .success(let place):
                        completion(.ok(["name": name, "host": host, "workspace": layoutWorkspace, "tab": place.tab,
                                        "pane": place.pane, "window": entry.state.windowStateId.uuidString]))
                    }
                }
            }
        }
    }

    // MARK: - 비동기 명령 (창을 열고 기다려야 하는 것들)

    /// 처리했으면 non-nil. 창 생성은 SwiftUI가 다음 run loop에서 AppState를 만들기 때문에
    /// 레지스트리에 새 창이 등록될 때까지 폴링한 뒤 응답한다.
    private static func dispatchAsync(_ r: ControlRequest, completion: @escaping (ControlResponse) -> Void) throws -> Bool? {
        // 노치 명령(Fine과 같은 이름·같은 모양). 노치를 누가 그리든 입구는 여기다.
        if r.command.hasPrefix("attention.") {
            NotchOwner.shared.handle(r, completion: completion)
            return true
        }
        switch r.command {
        case "window.new":
            openWindow { result in
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

        case "session.toFine":
            guard let target = r.string("target"), !target.isEmpty else { throw fail("usage: sm to-fine NAME[@HOST]") }
            moveToFine(target, completion: completion)
            return true

        case "session.reveal":
            guard let target = r.string("target"), !target.isEmpty else { throw fail("usage: sm reveal NAME[@HOST]") }
            // 그 세션을 Fine 탭이 보고 있으면(Fine으로 옮긴 세션, Fine이 띄운 세션) 그 탭을 앞으로 — 세션은 하나라도
            // 보는 앱은 그때그때 하나다. 아니면 sm 패널.
            let wantsFocus = r.bool("focus") ?? true
            FineControl.tab(showing: target, localHost: PeerDirectory.shared.localHostName) { tab in
                if let tab {
                    FineControl.request("tab.select", ["tab": tab, "focus": wantsFocus]) { reply in
                        switch reply {
                        case .ok: completion(.ok(["name": target, "fineTab": tab]))
                        case .failed(let message): completion(.error(message))
                        case .unreachable: completion(.error("Fine did not answer"))
                        }
                    }
                } else if let fineTab = r.string("fineTab") {
                    revealBeside(fineTab: fineTab, target, focus: wantsFocus, completion: completion)
                } else {
                    revealInSM(target, focus: wantsFocus, completion: completion)
                }
            }
            return true

        case "perf.keys":
            let entry = try window(r)
            guard let nsWindow = entry.window else { throw fail("window has no NSWindow yet") }
            guard let name = r.string("session") else { throw fail("usage: sm perf keys NAME [-n COUNT]") }
            KeyProbe.run(state: entry.state, window: nsWindow, session: name, count: min(max(r.int("count") ?? 40, 1), 200)) {
                switch $0 {
                case .success(let report): completion(.ok(report))
                case .failure(let error): completion(.error(error.message))
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

        default:
            return nil
        }
    }

    /// `sm perf --do`:사람이 누르는 것과 같은 길(⌘숫자, ⌥⌘←→, ⌘[ ⌘], 사이드바 클릭)로 한 번 움직인다.
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
            guard let workspace = state.workspaces.first(where: { $0.name == value || $0.layoutName == value }) else {
                throw fail("no workspace named \(value) in this window")
            }
            return { state.selectWorkspace(workspace) }
        default:
            throw fail("--do takes tab:N | tab:next | tab:prev | focus:next | focus:prev | ws:NAME")
        }
    }

    private static func openWindow(completion: @escaping (WindowEntry?) -> Void) {
        guard let open = WindowOpener.open else { completion(nil); return }
        let before = Set(liveWindows().map { $0.state.windowStateId })
        let id = UUID()
        open("main", id)
        NSApp.activate(ignoringOtherApps: true)
        var attempts = 0
        func poll() {
            if let entry = liveWindows().first(where: { $0.state.windowStateId == id || !before.contains($0.state.windowStateId) }) {
                completion(entry); return
            }
            attempts += 1
            if attempts > 40 { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    // MARK: - 대상 해석

    typealias WindowEntry = (state: AppState, window: NSWindow?)

    static func liveWindows() -> [WindowEntry] {
        WorkspaceWindowRegistry.shared.liveEntries()
    }

    private static func window(_ r: ControlRequest) throws -> WindowEntry {
        try window(query: r.string("window"))
    }

    private static func window(query: String?) throws -> WindowEntry {
        let entries = liveWindows()
        guard !entries.isEmpty else { throw fail("no windows open") }
        guard let query, !query.isEmpty, query != "front", query != "key" else {
            return entries.first { $0.window?.isKeyWindow == true } ?? entries.first { $0.window != nil } ?? entries[0]
        }
        if let index = Int(query), entries.indices.contains(index) { return entries[index] }
        if let hit = entries.first(where: { $0.state.windowStateId.uuidString.lowercased().hasPrefix(query.lowercased()) }) { return hit }
        if query.lowercased() == "workspace", let first = entries.first { return first }
        throw fail("window not found: \(query)")
    }

    private static func workspaceWindow(_ r: ControlRequest) throws -> WindowEntry {
        try window(r)
    }

    /// 워크스페이스 질의: id 접두사 / 이름 / 배치 이름 / 경로 / 경로 마지막 요소.
    static func matchWorkspace(_ query: String, in workspaces: [Workspace]) -> Workspace? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        let expanded = ((q as NSString).expandingTildeInPath as NSString).standardizingPath
        return workspaces.first { $0.id.uuidString.lowercased() == lower }
            ?? workspaces.first { $0.name == q }
            ?? workspaces.first { $0.effectiveLayoutName == q }
            ?? workspaces.first { $0.rootPath == expanded }
            ?? workspaces.first { $0.name.lowercased() == lower }
            ?? workspaces.first { ($0.rootPath as NSString).lastPathComponent.lowercased() == lower }
            ?? (q.count >= 4 ? workspaces.first { $0.id.uuidString.lowercased().hasPrefix(lower) } : nil)
    }

    private static func workspace(_ r: ControlRequest) throws -> (WindowEntry, Workspace) {
        guard let query = r.string("ws") else { throw fail("workspace required") }
        let candidates: [WindowEntry] = r.string("window") == nil ? liveWindows() : [try window(r)]
        for entry in candidates {
            if let ws = matchWorkspace(query, in: entry.state.workspaces) { return (entry, ws) }
        }
        throw fail("workspace not found: \(query)")
    }

    private static func refetch(_ ws: Workspace, in entry: WindowEntry) throws -> Workspace {
        guard let fresh = entry.state.workspaces.first(where: { $0.id == ws.id }) else { throw fail("workspace vanished") }
        return fresh
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
            "kind": "workspace",
            "isKey": entry.window?.isKeyWindow ?? false,
            "appearance": entry.state.preferredAppearance,
            "workspaceCount": entry.state.workspaces.count,
            "selectedWorkspace": entry.state.selectedWorkspace?.name ?? "",
            "tabCount": entry.state.selectedLayout?.tabs.count ?? 0,
        ]
    }

    private static func describe(_ ws: Workspace, in entry: WindowEntry) -> [String: Any] {
        [
            "id": ws.id.uuidString,
            "name": ws.name,
            "rootPath": ws.rootPath,
            "layout": ws.effectiveLayoutName,
            "tmuxSession": ws.effectiveLayoutName,   // 옛 sm CLI가 읽는 이름
            "customTmuxSession": ws.layoutName ?? "",
            "remoteHost": ws.remoteHost ?? "",
            "projects": ws.additionalProjects.map(\.path),
            "selected": entry.state.selectedWorkspace?.id == ws.id,
            "window": entry.state.windowStateId.uuidString,
        ]
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
}
