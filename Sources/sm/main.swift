import Foundation

// sm — SpaceManager CLI. 앱의 제어 소켓(~/.space-manager/control.sock)에 JSON 한 줄을 보내고
// 응답을 사람이 읽기 좋게, 또는 --json으로 그대로 출력한다. 앱이 안 떠 있으면 띄우고 기다린다.

let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".space-manager/control.sock")
let bundleID = "com.spacemanager.app"

let appUsage = """
Mac app (sm here also draws the layout above; these verbs exist only on the Mac):
  sm show NAME[@HOST]       Put that agent in front of SEOL — its sm pane (keys go to it), or the Fine tab that
                            shows it; nowhere yet → a new tab. A workspace name selects that workspace instead.
                            This is the only command that moves SEOL's focus; layout commands never do.
  sm show | hide | toggle   Show or hide all sm windows (the menu bar icon does the same; the notch stays)
  sm to-fine NAME[@HOST]    Move the pane showing NAME to a Fine tab (the session keeps running). Back: fine move TAB sm
  sm notify MESSAGE [--title T] [--state waiting|blocked|error|working|done] [--id KEY] [--source sm:NAME]
                            Post to the notch (same --id updates it). To call SEOL use seol-notch instead.
  sm notch [list] | dismiss ID | open ID | show | hide | status
  sm capture [-w WIN] FILE.png [--rect x,y,w,h]   Picture of an sm window only (never the whole screen)
  sm windows | sm window new|focus|close WIN | sm tabs [WS]
  sm quick [list|new|resume ID|home] · sm activity · sm perf … · sm ping
  sm app ws|tab|state …     The app's older commands (sidebar rename/select/delete/remote, shell/tmux tabs,
                            window-states dump). `sm ws`/`sm tab` are the session layer's, as on every machine.

  On the Mac, `sm ws` lists the layouts together with SEOL's sidebar (the --ws value to type and the name SEOL
  uses), `sm ws new NAME [--cwd DIR] [--host arch] [-w WINDOW]` also adds it to the sidebar of that window (default:
  the front one; sm windows lists them) without switching SEOL's view,
  and --ws accepts the sidebar name (--ws 인체안내서 → saengjon, --ws flat → flat@arch).
  Options: --json, -w/--window ID|INDEX|front, --no-focus
"""

struct CLIError: Error { let message: String }

/// 터미널에서 한글·한자는 두 칸이다. 칸을 글자 수로 맞추면 "인체안내서" 뒤 열이 밀린다.
func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { width, u in
        let v = u.value
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
        return width + (wide ? 2 : 1)
    }
}

func pad(_ text: String, _ width: Int) -> String { text + String(repeating: " ", count: max(0, width - displayWidth(text))) }

/// 칸을 맞춘 표. 마지막 열은 채우지 않는다.
func alignedTable(_ rows: [[String]]) -> String {
    guard let first = rows.first else { return "(none)" }
    var widths = Array(repeating: 0, count: first.count)
    for row in rows { for (i, c) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], displayWidth(c)) } }
    return rows.map { row in
        row.enumerated().map { i, c in i == row.count - 1 ? c : pad(c, widths[i]) }.joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }.joined(separator: "\n")
}

func send(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
    if !FileManager.default.fileExists(atPath: socketPath) {
        FileHandle.standardError.write("sm: SpaceManager not running — launching…\n".data(using: .utf8)!)
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-g", "-b", bundleID]
        try open.run(); open.waitUntilExit()
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: socketPath) && Date() < deadline { usleep(200_000) }
        usleep(300_000)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError(message: "socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard rc == 0 else { throw CLIError(message: "cannot connect to \(socketPath): \(String(cString: strerror(errno))) — is SpaceManager (with control server) running?") }
    var payload = try JSONSerialization.data(withJSONObject: ["command": command, "args": args])
    payload.append(UInt8(ascii: "\n"))
    payload.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress!, raw.count) }
    var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n); if data.last == UInt8(ascii: "\n") { break } }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError(message: "bad response") }
    if obj["ok"] as? Bool != true { throw CLIError(message: obj["error"] as? String ?? "unknown error") }
    return obj
}

// MARK: - 인자 파싱

// 맥의 `sm`은 아치·누크의 `sm`과 같은 명령이다(11/01 SEOL: 에이전트가 sm을 헷갈리지 않게). 바탕은 기기마다 도는
// 세션 층(sm-session)이고, 이 앱은 앱만 하는 동사만 더한다 — 창·노치·숨기기·찍기·SEOL 앞에 꺼내기.
// 전에는 세션 동사를 하나씩 골라 넘겨서 run·cp·state·screen·awake가 "unknown command"였고(pet-1101-8acc),
// ws·tab·state는 같은 이름의 앱 명령으로 가서 에이전트가 "맥에서는 sm-session ws"라는 예외를 외워야 했다.
// 그래서 목록을 뒤집었다: 아래 앱 동사가 아니면 전부 세션 층으로 간다. 세션 층에 새 동사가 생겨도 여기를 고칠 일이 없다.
// 옛 앱 명령(ws add·select…, tab shell·tmux…, state 덤프)은 `sm app …` 아래로 옮겼다.
let appVerbs: Set<String> = ["app", "windows", "window", "workspaces", "tabs", "project", "quick", "capture", "perf",
                             "activity", "ping", "notify", "notch", "show", "reveal", "hide", "toggle", "to-fine"]
let sessionCLI = (NSHomeDirectory() as NSString).appendingPathComponent(".smux/bin/sm-session")

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("sm: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func note(_ message: String) { FileHandle.standardError.write(("sm: " + message + "\n").data(using: .utf8)!) }

func execLayer(_ args: [String]) -> Never {
    guard FileManager.default.isExecutableFile(atPath: sessionCLI) else {
        fail("\(args.first ?? "")는 세션 층(~/.smux/bin/sm-session)이 맡는데, 이 기기에 없습니다", code: 127)
    }
    let cArgs = ([sessionCLI] + args).map { strdup($0) } + [nil]
    execv(sessionCLI, cArgs)
    fail("sm-session 실행 실패: \(String(cString: strerror(errno)))", code: 126)
}

/// 세션 층을 불러 출력을 받는다(맥에서 결과를 앱 쪽 사실과 합칠 때만).
func runLayer(_ args: [String]) -> (status: Int32, out: Data, err: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: sessionCLI); p.arguments = args
    let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return (127, Data(), "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, data, errText)
}

/// 앱이 이미 떠 있을 때만 묻는다 — 목록을 보거나 이름을 풀려고 SEOL 화면에 앱을 띄우지 않는다.
func askAppIfRunning(_ command: String, _ args: [String: Any] = [:]) -> Any? {
    guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
    return (try? send(command, args))?["result"]
}

/// 사이드바의 실행 위치(ssh 별칭: arch, nuc-pet)를 세션 층의 기기 이름(arch, nuc)으로. `~/.smux/hosts`의 `이름 = 별칭`.
func layerHost(forAlias alias: String) -> String {
    let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.smux/hosts", encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[1] == alias { return parts[0] }
    }
    return alias
}

/// SEOL이 부르는 워크스페이스 이름(사이드바: "인체안내서", "flat")을 세션 층의 `--ws` 값("saengjon", "flat@arch")으로.
/// 맥 에이전트가 사이드바 이름으로 말해도 원격·이름 다른 배치에 닿게 한다. 이미 `@HOST`가 붙었거나 모르는 이름은 그대로.
func layerWorkspace(_ value: String) -> String {
    guard !value.contains("@"), let rows = askAppIfRunning("ws.list") as? [[String: Any]] else { return value }
    func field(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
    let match = rows.first { field($0, "tmuxSession") == value }
        ?? rows.first { field($0, "name") == value }
        ?? rows.first { field($0, "name").lowercased() == value.lowercased() }
    guard let row = match else { return value }
    let remote = field(row, "remoteHost")
    return field(row, "tmuxSession") + (remote.isEmpty ? "" : "@" + layerHost(forAlias: remote))
}

func rewriteWorkspaceFlags(_ args: [String]) -> [String] {
    var out = args
    var i = 0
    while i < out.count {
        if out[i] == "--" { break }
        if out[i] == "--ws", i + 1 < out.count { out[i + 1] = layerWorkspace(out[i + 1]); i += 2; continue }
        if out[i].hasPrefix("--ws=") { out[i] = "--ws=" + layerWorkspace(String(out[i].dropFirst(5))) }
        i += 1
    }
    // `sm layout WS`: 첫 인자가 워크스페이스다.
    if out.first == "layout", out.count > 1, !out[1].hasPrefix("-") { out[1] = layerWorkspace(out[1]) }
    return out
}

/// `sm ws`(목록): 세션 층의 배치와 SEOL 사이드바를 한 표로. 에이전트가 알아야 할 것은 `--ws`에 칠 값과,
/// SEOL이 그걸 무슨 이름으로 부르고 지금 보고 있는지다.
func listWorkspaces(json: Bool) -> Never {
    let layer = runLayer(["ws", "ls", "--json"])
    let layouts = (try? JSONSerialization.jsonObject(with: layer.out)) as? [[String: Any]] ?? []
    let localHost = layouts.first?["host"] as? String ?? "mac"
    let sidebar = askAppIfRunning("ws.list") as? [[String: Any]]
    var rows: [[String: Any]] = []
    var seen = Set<String>()
    for w in sidebar ?? [] {
        let alias = w["remoteHost"] as? String ?? ""
        let host = alias.isEmpty ? localHost : layerHost(forAlias: alias)
        let name = w["tmuxSession"] as? String ?? ""
        let layout = alias.isEmpty ? layouts.first { $0["workspace"] as? String == name } : nil
        seen.insert(name + "@" + host)
        rows.append(["ws": alias.isEmpty ? name : name + "@" + host, "workspace": name, "host": host,
                     "name": w["name"] as? String ?? name, "cwd": layout?["cwd"] as? String ?? w["rootPath"] as? String ?? "",
                     "tabs": layout?["tabs"] ?? NSNull(), "in_sidebar": true, "selected": w["selected"] as? Bool ?? false])
    }
    for l in layouts {
        let name = l["workspace"] as? String ?? "", host = l["host"] as? String ?? localHost
        guard !seen.contains(name + "@" + host) else { continue }
        rows.append(["ws": name, "workspace": name, "host": host, "name": NSNull(), "cwd": l["cwd"] as? String ?? "",
                     "tabs": l["tabs"] ?? NSNull(), "in_sidebar": false, "selected": false])
    }
    if json {
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self)); exit(0)
    }
    func home(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~").replacingOccurrences(of: "/home/" + NSUserName(), with: "~")
    }
    var table = [["--ws", "SEOL이 보는 이름", "탭", "폴더", ""]]
    for r in rows {
        let tabs = r["tabs"] as? Int
        let shown = r["in_sidebar"] as? Bool == true ? (r["selected"] as? Bool == true ? "보는 중" : "") : "사이드바 밖"
        table.append([r["ws"] as? String ?? "", r["name"] as? String ?? "-", tabs.map(String.init) ?? "-", home(r["cwd"] as? String ?? ""), shown])
    }
    print(alignedTable(table))
    if sidebar == nil { print("(sm 앱이 꺼져 있어 사이드바는 빼고 이 맥의 배치만)") }
    exit(0)
}

/// `sm ws new NAME[@HOST] [--cwd DIR] [--host H]`: 배치를 그 기기에 만들고, SEOL 사이드바에도 넣는다(고르지는 않는다 —
/// SEOL이 보던 워크스페이스는 그대로). 아치에서 만든 배치는 이 앱이 모르므로, 맥에서 만들면 둘 다 한 번에 된다.
func newWorkspace(_ rest: [String], json: Bool) -> Never {
    var name: String?, cwd: String?, host: String?, window: String? = windowFlagBeforeVerb
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--cwd": i += 1; cwd = i < rest.count ? rest[i] : nil
        case "--host": i += 1; host = i < rest.count ? rest[i] : nil
        case "-w", "--window": i += 1; window = i < rest.count ? rest[i] : nil
        case "--name": i += 1; name = i < rest.count ? rest[i] : nil
        case let a where a.hasPrefix("-"): fail("sm ws new: 모르는 옵션 \(a) — sm ws new NAME [--cwd DIR] [--host arch] [-w WINDOW] (창은 sm windows)")
        default: if name == nil { name = rest[i] } else { fail("sm ws new: 이름은 하나 — sm ws new NAME [--cwd DIR] [--host arch]") }
        }
        i += 1
    }
    guard var target = name, !target.isEmpty else { fail("usage: sm ws new NAME [--cwd DIR] [--host arch]") }
    if let host, !target.contains("@") { target += "@" + layerHost(forAlias: host) }
    let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
    let remote = parts.count == 2 && parts[1] != "mac" && parts[1] != "local" ? parts[1] : nil
    // 원격은 그 기기의 폴더다. 안 주면 그 기기의 홈(~)이 아니라 같은 이름의 ~/폴더를 가정하지 않고, 홈에 둔다.
    let dir = cwd ?? (remote == nil ? FileManager.default.currentDirectoryPath : "~")
    var made = runLayer(["ws", "new", remote == nil ? parts[0] : target, "--cwd", dir, "--no-app", "--json"])
    var existed = false
    if made.status != 0 {
        guard made.err.contains("workspace exists") else { fail(made.err.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "sm: ", with: "")) }
        existed = true
        made = runLayer(["layout", remote == nil ? parts[0] : target, "--json"])
        if made.status != 0 { fail(made.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let layout = (try? JSONSerialization.jsonObject(with: made.out)) as? [String: Any] ?? [:]
    let layoutCwd = layout["cwd"] as? String ?? dir
    // 원격 홈(/home/USER)은 사이드바에서 ~로 쓴다 — 앱은 원격 경로를 ~ 기준으로 그 기기에서 푼다.
    let sidebarPath = remote == nil ? layoutCwd : layoutCwd.replacingOccurrences(of: "^/home/[^/]+", with: "~", options: .regularExpression)
    var sidebarNote = "sm 앱이 꺼져 있어 사이드바에는 아직 없음 — 앱을 켜고 sm ws new를 다시 부르면 들어간다"
    var addedArgs: [String: Any] = ["path": sidebarPath, "name": parts[0], "layout": parts[0], "select": false]
    if let remote { addedArgs["host"] = remoteAlias(forHost: remote) }
    if let window { addedArgs["window"] = window }  // 없으면 앞에 있는 창(sm windows로 번호·id를 본다)
    if FileManager.default.fileExists(atPath: socketPath) {
        do {
            let result = try send("ws.add", addedArgs)["result"] as? [String: Any] ?? [:]
            sidebarNote = result["existed"] as? Bool == true ? "사이드바에 이미 있음" : "사이드바에 넣음(SEOL이 보던 워크스페이스는 그대로)"
        } catch let error as CLIError { sidebarNote = "사이드바에 넣지 못함: " + error.message }
        catch { sidebarNote = "사이드바에 넣지 못함: \(error)" }
    }
    let ws = remote == nil ? parts[0] : target
    if json {
        let value: [String: Any] = ["ws": ws, "cwd": layoutCwd, "existed": existed, "sidebar": sidebarNote]
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self)); exit(0)
    }
    print("\(existed ? "이미 있음" : "만듦"): --ws \(ws) · \(layoutCwd) · \(sidebarNote)")
    print("다음: sm tab new --ws \(ws) --name main --spawn NAME --kind claude  /  sm split --ws \(ws) --spawn NAME --kind codex")
    exit(0)
}

/// 세션 층의 기기 이름(nuc)을 사이드바의 ssh 별칭(nuc-pet)으로 — layerHost의 반대.
func remoteAlias(forHost host: String) -> String {
    let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.smux/hosts", encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == host { return parts[1] }
    }
    return host
}


// MARK: - 워크스페이스(사이드바와 배치를 함께)

struct SidebarEntry { let id: String; let window: String; let name: String; let layout: String; let host: String; let alias: String; let selected: Bool }

func sidebarEntries() -> [SidebarEntry]? {
    guard let rows = askAppIfRunning("ws.list") as? [[String: Any]] else { return nil }
    return rows.map { w in
        let alias = w["remoteHost"] as? String ?? ""
        return SidebarEntry(id: w["id"] as? String ?? "", window: w["window"] as? String ?? "", name: w["name"] as? String ?? "",
                            layout: w["tmuxSession"] as? String ?? "", host: alias.isEmpty ? "mac" : layerHost(forAlias: alias),
                            alias: alias, selected: w["selected"] as? Bool ?? false)
    }
}

/// 사이드바 항목 하나: `--ws` 값(saengjon, flat@arch), 배치 이름, SEOL이 부르는 이름(인체안내서) 무엇으로든.
func findSidebar(_ ref: String, in entries: [SidebarEntry]) -> SidebarEntry? {
    let parts = ref.split(separator: "@", maxSplits: 1).map(String.init)
    if parts.count == 2 { return entries.first { $0.layout == parts[0] && $0.host == layerHost(forAlias: parts[1]) } }
    return entries.first { $0.layout == ref } ?? entries.first { $0.name == ref }
        ?? entries.first { $0.name.lowercased() == ref.lowercased() } ?? entries.first { $0.id.lowercased().hasPrefix(ref.lowercased()) && ref.count >= 4 }
}

func wsRef(_ e: SidebarEntry) -> String { e.host == "mac" ? e.layout : e.layout + "@" + e.host }

func requireSidebar(_ ref: String) -> (SidebarEntry, [SidebarEntry]) {
    guard let entries = sidebarEntries() else { fail("sm 앱이 꺼져 있다 — 사이드바는 앱이 켜져 있어야 바꾼다 (open -a WorkspaceManager)") }
    guard let entry = findSidebar(ref, in: entries) else {
        let names = entries.map { $0.name == $0.layout ? wsRef($0) : "\(wsRef($0))(\($0.name))" }
        fail("사이드바에 \(ref) 워크스페이스가 없다 — 있는 것: " + names.joined(separator: ", "))
    }
    return (entry, entries)
}

/// 바꾼 뒤 그 창의 사이드바 순서를 한 줄로(* = SEOL이 보는 것).
func printSidebarOrder(window: String) {
    let order = (sidebarEntries() ?? []).filter { $0.window == window }
    print("사이드바(창 \(window.prefix(8).lowercased())): " + order.map { ($0.selected ? "*" : "") + $0.name }.joined(separator: " · "))
}

func appCall(_ command: String, _ args: [String: Any]) -> Any {
    do { return try send(command, args)["result"] ?? NSNull() }
    catch let error as CLIError { fail(error.message) }
    catch { fail("\(error)") }
}

func removeWorkspace(_ ref: String, json: Bool) -> Never {
    let entries = sidebarEntries()
    let entry = entries.flatMap { findSidebar(ref, in: $0) }
    let target = entry.map(wsRef) ?? ref
    let removed = runLayer(["ws", "rm", target, "--no-app", "--json"])
    let layer = (try? JSONSerialization.jsonObject(with: removed.out)) as? [String: Any]
    if removed.status != 0 && entry == nil {
        fail(removed.err.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "sm: ", with: "")
             + (entries == nil ? "" : " — 사이드바에도 없다 (sm ws)"))
    }
    if let entry { _ = appCall("ws.delete", ["ws": entry.id, "window": entry.window]) }
    let sessions = layer?["sessions"] as? [String] ?? []
    if json {
        let value: [String: Any] = ["ws": target, "layout_removed": removed.status == 0, "sidebar_removed": entry != nil, "sessions": sessions]
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self)); exit(0)
    }
    var line = "지움: \(target)"
    line += removed.status == 0 ? " · 배치" : " · (배치는 없었다)"
    line += entry != nil ? " · 사이드바" : ""
    if !sessions.isEmpty { line += " — 세션은 뒤에서 계속 돈다: " + sessions.joined(separator: ", ") + " (끝내려면 sm stop NAME)" }
    print(line)
    if let entry { printSidebarOrder(window: entry.window) }
    exit(0)
}

/// 사이드바 순서: INDEX(0부터) | first | last | up | down | --before WS | --after WS.
func moveWorkspace(_ rest: [String]) -> Never {
    guard rest.count >= 2 else { fail("usage: sm ws move WS INDEX|first|last|up|down|--before WS|--after WS") }
    let (entry, entries) = requireSidebar(rest[0])
    var order = entries.filter { $0.window == entry.window }
    guard let from = order.firstIndex(where: { $0.id == entry.id }) else { fail("사이드바 순서를 읽지 못했다") }
    order.remove(at: from)
    let to: Int
    switch rest[1] {
    case "first", "top": to = 0
    case "last", "bottom": to = order.count
    case "up": to = max(0, from - 1)
    case "down": to = min(order.count, from + 1)
    case "--before", "--after":
        guard rest.count >= 3, let other = findSidebar(rest[2], in: order), let j = order.firstIndex(where: { $0.id == other.id }) else {
            fail("sm ws move: \(rest.count >= 3 ? rest[2] + "가 같은 창 사이드바에 없다" : "--before/--after 뒤에 워크스페이스")")
        }
        to = rest[1] == "--before" ? j : j + 1
    case let n where Int(n) != nil: to = max(0, min(order.count, Int(n)!))
    default: fail("sm ws move WS INDEX|first|last|up|down|--before WS|--after WS (받은 것: \(rest[1]))")
    }
    _ = appCall("ws.move", ["ws": entry.id, "window": entry.window, "index": to])
    printSidebarOrder(window: entry.window)
    exit(0)
}

func printHelp() -> Never {
    if FileManager.default.isExecutableFile(atPath: sessionCLI) {
        let help = runLayer(["--help"])
        FileHandle.standardOutput.write(help.out)
        print("")
    }
    print(appUsage)
    exit(0)
}

var argv = Array(CommandLine.arguments.dropFirst())
let globalFlagsWithValue: Set<String> = ["-w", "--window"]
let verbIndex: Int? = {
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if globalFlagsWithValue.contains(a) { i += 2; continue }
        if a.hasPrefix("-") && a != "-h" { i += 1; continue }
        return i
    }
    return nil
}()
let verb = verbIndex.map { argv[$0] }
// `sm -w 1 ws new X`: 동사 앞의 창 지정(세션 층으로 넘기지 않는 ws 처리에서 쓴다).
let windowFlagBeforeVerb: String? = {
    guard let end = verbIndex else { return nil }
    for flag in ["-w", "--window"] {
        if let i = argv[..<end].firstIndex(of: flag), i + 1 < end { return argv[i + 1] }
    }
    return nil
}()
let wantsJSON = argv.contains("--json")
switch verb {
case nil:
    printHelp()
case "-h", "help":
    printHelp()
case "app":
    // 앱 명령을 이름 그대로(옛 ws·tab·state 포함).
    argv.remove(at: verbIndex!)
    if argv.isEmpty || argv == ["--help"] || argv == ["-h"] { print(appUsage); exit(0) }
case "ws":
    let rest = Array(argv[(verbIndex! + 1)...]).filter { $0 != "--json" }
    switch rest.first {
    case nil, "ls", "list": listWorkspaces(json: wantsJSON)
    case "new": newWorkspace(Array(rest.dropFirst()), json: wantsJSON)
    case "add":
        // 옛 앱 명령 `sm ws add PATH [--name N] [--host H]` — 이제 배치까지 만든다(tmux가 아니라 세션 층 워크스페이스).
        var path: String?, name: String?, host: String?
        var i = 1
        while i < rest.count {
            switch rest[i] {
            case "--name": i += 1; name = i < rest.count ? rest[i] : nil
            case "--host": i += 1; host = i < rest.count ? rest[i] : nil
            default: path = path ?? rest[i]
            }
            i += 1
        }
        guard let path else { fail("usage: sm ws new NAME [--cwd DIR] [--host arch]  (sm ws add PATH도 받는다)") }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
        let layoutName = (name ?? folder).lowercased().replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
        var args = [layoutName, "--cwd", path]
        if let host, !["local", "none", "-"].contains(host) { args += ["--host", host] }
        newWorkspace(args, json: wantsJSON)
    case "rm", "remove", "delete":
        guard rest.count == 2 else { fail("usage: sm ws rm WS   (세션은 끝나지 않는다 — 끝내려면 sm stop NAME)") }
        removeWorkspace(rest[1], json: wantsJSON)
    case "move":
        moveWorkspace(Array(rest.dropFirst()))
    case "rename":
        guard rest.count == 3 else { fail("usage: sm ws rename WS 새이름   (SEOL이 보는 이름만 바뀐다 — --ws 값은 그대로)") }
        let (entry, _) = requireSidebar(rest[1])
        _ = appCall("ws.rename", ["ws": entry.id, "window": entry.window, "name": rest[2]])
        print("이름: \(entry.name) → \(rest[2]) (--ws \(wsRef(entry))는 그대로)")
        printSidebarOrder(window: entry.window)
        exit(0)
    case "select", "show":
        guard rest.count == 2 else { fail("usage: sm ws select WS   (SEOL 화면에 그 워크스페이스를 띄운다 — sm show WS와 같다)") }
        let (entry, _) = requireSidebar(rest[1])
        _ = appCall("ws.select", ["ws": entry.id, "window": entry.window])
        printSidebarOrder(window: entry.window)
        exit(0)
    case "tmux-name", "remote":
        note("ws \(rest[0])는 앱 명령이다 — 앞으로 sm app ws \(rest[0]) … (이번엔 그대로 한다)")
    default:
        execLayer(rewriteWorkspaceFlags(argv))
    }
case "tab":
    let sub = verbIndex! + 1 < argv.count ? argv[verbIndex! + 1] : nil
    if let sub, ["shell", "tmux", "reconnect", "next", "prev"].contains(sub) {
        note("tab \(sub)는 앱 명령이다 — 앞으로 sm app tab \(sub) … (이번엔 그대로 한다)")
    } else {
        execLayer(rewriteWorkspaceFlags(argv))
    }
case let v? where appVerbs.contains(v):
    break
default:
    execLayer(rewriteWorkspaceFlags(argv))
}
var wantJSON = false
var windowArg: String?
var noFocus = false
var positional: [String] = []
var flags: [String: String] = [:]
var i = 0
while i < argv.count {
    let a = argv[i]
    switch a {
    case "--json": wantJSON = true
    case "--no-focus": noFocus = true
    case "-w", "--window": i += 1; windowArg = i < argv.count ? argv[i] : nil
    case "--quick", "--proxy": flags[String(a.dropFirst(2))] = "true"
    case "--name", "--host", "--model", "--effort", "-n", "--limit", "--rect", "--burst", "--every", "--do",
         "--title", "--state", "--id", "--source", "--workspace":
        i += 1; flags[a.hasPrefix("--") ? String(a.dropFirst(2)) : "limit"] = i < argv.count ? argv[i] : ""
    case "-h", "--help", "help": print(appUsage); exit(0)
    default: positional.append(a)
    }
    i += 1
}
guard let group = positional.first else { print(appUsage); exit(1) }
let sub = positional.count > 1 ? positional[1] : nil
let rest = Array(positional.dropFirst(2))
var args: [String: Any] = [:]
if let windowArg { args["window"] = windowArg }
if noFocus { args["focus"] = false }

func need(_ n: Int, _ what: String) throws -> [String] {
    guard rest.count >= n else { throw CLIError(message: "usage: \(what)") }
    return rest
}

var command: String
do {
    switch (group, sub) {
    case ("ping", _): command = "ping"
    case ("windows", _): command = "windows.list"
    case ("window", "new"): command = "window.new"; if flags["quick"] != nil { args["kind"] = "quick" }
    case ("window", "focus"), ("window", "close"):
        command = "window.\(sub!)"; args["window"] = try need(1, "sm window \(sub!) <win>")[0]
    case ("window", "appearance"):
        let a = try need(2, "sm window appearance <win> <light|dark|system>"); command = "window.appearance"; args["window"] = a[0]; args["value"] = a[1]
    case ("ws", nil), ("ws", "list"), ("workspaces", _): command = "ws.list"
    case ("ws", "add"):
        command = "ws.add"; args["path"] = try need(1, "sm ws add <path> [--host arch|local]")[0]
        if let n = flags["name"] { args["name"] = n }
        if let host = flags["host"] { args["host"] = host }
    case ("ws", "select"), ("ws", "delete"): command = "ws.\(sub!)"; args["ws"] = try need(1, "sm ws \(sub!) <ws>")[0]
    case ("ws", "rename"): let a = try need(1, "sm ws rename <ws> <name>"); command = "ws.rename"; args["ws"] = a[0]; args["name"] = a.count > 1 ? a[1] : ""
    case ("ws", "tmux-name"): let a = try need(1, "sm ws tmux-name <ws> <name>"); command = "ws.tmuxName"; args["ws"] = a[0]; args["name"] = a.count > 1 ? a[1] : ""
    case ("ws", "remote"): let a = try need(2, "sm ws remote <ws> <host|none>"); command = "ws.remote"; args["ws"] = a[0]; args["host"] = a[1]
    case ("ws", "move"): let a = try need(2, "sm ws move <ws> <index>"); command = "ws.move"; args["ws"] = a[0]; args["index"] = Int(a[1]) ?? 0
    case ("project", "add"), ("project", "remove"):
        let a = try need(2, "sm project \(sub!) <ws> <path>"); command = "project.\(sub!)"; args["ws"] = a[0]; args["path"] = a[1]
    case ("tabs", _): command = "tab.list"; if let s = sub { args["ws"] = s }
    case ("tab", "list"): command = "tab.list"; if let w = rest.first { args["ws"] = w }
    case ("tab", "shell"), ("tab", "tmux"): command = "tab.\(sub!)"; if let w = rest.first { args["ws"] = w }
    case ("tab", "select"), ("tab", "close"), ("tab", "reconnect"): command = "tab.\(sub!)"; args["tab"] = try need(1, "sm tab \(sub!) <tab>")[0]
    case ("tab", "next"), ("tab", "prev"): command = "tab.\(sub!)"
    case ("quick", nil), ("quick", "list"): command = "quick.list"; args["limit"] = Int(flags["limit"] ?? "30") ?? 30
    case ("quick", "new"):
        command = "quick.new"; let prompt = rest.joined(separator: " "); if !prompt.isEmpty { args["prompt"] = prompt }
        if let m = flags["model"] { args["model"] = m }; if let e = flags["effort"] { args["effort"] = e }; if flags["proxy"] != nil { args["proxy"] = true }
    case ("quick", "resume"): command = "quick.resume"; args["id"] = try need(1, "sm quick resume <session-id>")[0]
    case ("quick", "home"): command = "quick.home"
    case ("capture", _):
        command = "window.capture"
        if let path = sub { args["path"] = (path as NSString).expandingTildeInPath.hasPrefix("/") ? (path as NSString).expandingTildeInPath : FileManager.default.currentDirectoryPath + "/" + path }
        if let rect = flags["rect"] { args["rect"] = rect }
        if let burst = flags["burst"] { args["burst"] = Int(burst) ?? 1 }
        if let every = flags["every"] { args["every"] = Int(every) ?? 8 }
        if args["path"] == nil && args["burst"] == nil { throw CLIError(message: "usage: sm capture <file.png> | sm capture --rect x,y,w,h --burst N [dir]") }
    case ("show", _?), ("reveal", _):
        command = "session.reveal"
        guard let target = sub else { throw CLIError(message: "usage: sm show NAME[@HOST]") }
        args["target"] = target
        // An agent's call brings the pane forward inside sm but does not pull SEOL out of the app being used
        // (11/06). SEOL's own terminal (no PEER_NAME) still switches to it.
        if ProcessInfo.processInfo.environment["PEER_NAME"] != nil { args["focus"] = false }
    case ("perf", "keys"):
        command = "perf.keys"
        args["session"] = try need(1, "sm perf keys NAME [-n COUNT]  (NAME must start with sm-bench-)")[0]
        if let n = flags["limit"] { args["count"] = Int(n) ?? 40 }
    case ("perf", _):
        command = "perf.frames"; if let s = sub { args["seconds"] = s }
        if let action = flags["do"] { args["do"] = action }
        if let rect = flags["rect"] { args["rect"] = rect }
    case ("activity", _): command = "activity.list"
    case ("state", _): command = "state.dump"
    case ("hide", _): command = "app.hide"
    case ("show", nil): command = "app.show"
    case ("toggle", _): command = "app.toggle"
    case ("to-fine", _):
        command = "session.toFine"
        guard let target = sub else { throw CLIError(message: "usage: sm to-fine NAME[@HOST]") }
        args["target"] = target
    case ("notify", _):
        command = "attention.post"
        let message = ([sub].compactMap { $0 } + rest).joined(separator: " ")
        guard !message.isEmpty else { throw CLIError(message: "usage: sm notify <message> [--title T] [--state S] [--id KEY]") }
        args = ["message": message, "key": flags["id"] ?? UUID().uuidString.lowercased(), "host": flags["host"] ?? "local"]
        for field in ["title", "state", "source", "workspace"] { if let value = flags[field] { args[field] = value } }
    case ("notch", nil), ("notch", "list"): command = "attention.list"
    case ("notch", "dismiss"): command = "attention.dismiss"; args["id"] = try need(1, "sm notch dismiss <id>")[0]
    case ("notch", "open"): command = "attention.open"; args["id"] = try need(1, "sm notch open <id>")[0]
    case ("notch", "show"): command = "attention.show"
    case ("notch", "hide"): command = "attention.hide"
    case ("notch", "status"): command = "attention.status"
    default: throw CLIError(message: "unknown command: \(positional.joined(separator: " "))\n\n\(appUsage)")
    }
    var response: [String: Any]
    do {
        response = try send(command, args)
    } catch let error as CLIError where command == "session.reveal" {
        // "그거 내 화면에 띄워"의 그거가 세션이 아니라 워크스페이스일 수 있다(사이드바 이름·--ws 값).
        guard let target = args["target"] as? String,
              let shown = try? send("ws.select", ["ws": target.split(separator: "@").first.map(String.init) ?? target,
                                                  "focus": args["focus"] as? Bool ?? true]) else {
            throw CLIError(message: error.message.replacingOccurrences(of: "sm: ", with: "") + "\n  세션도 사이드바 워크스페이스도 아니다 — sm ls(세션), sm ws(워크스페이스)")
        }
        response = shown; command = "ws.select"
    }
    let result = response["result"] ?? NSNull()
    if wantJSON {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(render(command: command, result: result))
    }
} catch let error as CLIError {
    FileHandle.standardError.write("sm: \(error.message)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("sm: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 사람이 읽는 출력

func render(command: String, result: Any) -> String {
    func table(_ rows: [[String]]) -> String { alignedTable(rows) }
    func short(_ id: Any?) -> String { String((id as? String ?? "").prefix(8)).lowercased() }
    // NSNumber는 Bool로도 브리징되므로 CFBoolean인지 먼저 가려야 0/1이 yes/no로 둔갑하지 않는다
    func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "yes" : "" }
            return n.stringValue
        }
        return ""
    }
    func home(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    switch command {
    case "windows.list":
        let rows = (result as? [[String: Any]] ?? []).enumerated().map { i, w in
            [String(i), short(w["id"]), str(w["kind"]), str(w["isKey"]) == "yes" ? "*" : "", str(w["selectedWorkspace"]), "\(str(w["workspaceCount"])) ws", "\(str(w["tabCount"])) tabs", str(w["appearance"])]
        }
        return table([["#", "id", "kind", "key", "selected", "", "", "look"]] + rows)
    case "attention.list":
        let rows = (result as? [[String: Any]] ?? []).map { n in
            [str(n["state"]), str(n["host"]), str(n["title"]), String(str(n["message"]).prefix(50)), str(n["id"])]
        }
        return table([["state", "host", "title", "message", "id"]] + rows)
    case "attention.post":
        return str((result as? [String: Any])?["id"])
    case "ws.list", "ws.move":
        let rows = (result as? [[String: Any]] ?? []).map { w in
            [str(w["selected"]) == "yes" ? "*" : "", str(w["name"]), str(w["tmuxSession"]), str(w["remoteHost"]).isEmpty ? "local" : "@" + str(w["remoteHost"]), home(str(w["rootPath"])), short(w["window"])]
        }
        return table([["", "name", "tmux", "host", "path", "win"]] + rows)
    case "tab.list":
        let rows = (result as? [[String: Any]] ?? []).enumerated().map { i, t in
            [String(i), str(t["selected"]) == "yes" ? "*" : "", str(t["kind"]), str(t["name"]), str(t["remoteHost"]).isEmpty ? "" : "@" + str(t["remoteHost"]), str(t["reconnecting"]) == "yes" ? "reconnecting" : str(t["running"]) == "yes" ? "running" : "idle", short(t["id"])]
        }
        return table([["#", "", "kind", "name", "host", "state", "id"]] + rows)
    case "quick.list":
        let rows = (result as? [[String: Any]] ?? []).map { c in [str(c["id"]), String(str(c["modifiedAt"]).prefix(16)), str(c["title"])] }
        return table([["session-id", "modified", "title"]] + rows)
    case "activity.list":
        guard let dict = result as? [String: Any] else { return "\(result)" }
        let rows = (dict["sessions"] as? [[String: Any]] ?? []).map { s in [str(s["provider"]), String(str(s["lastActivity"]).prefix(16)), home(str(s["cwd"])), String(str(s["snippet"]).prefix(60))] }
        let generating = (dict["generating"] as? [String] ?? []).map(home)
        return table([["agent", "last", "cwd", "last prompt"]] + rows) + (generating.isEmpty ? "" : "\n\ngenerating: " + generating.joined(separator: ", "))
    default:
        if let dict = result as? [String: Any] {
            return dict.keys.sorted().map { k in "\(k): \(str(dict[k]).isEmpty ? "\(dict[k] ?? "")" : str(dict[k]))" }.joined(separator: "\n")
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { return String(decoding: data, as: UTF8.self) }
        return "\(result)"
    }
}
