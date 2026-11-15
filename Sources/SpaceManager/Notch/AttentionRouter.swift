import Foundation

/// 노치의 알림을 누르면 그 알림을 올린 곳을 앞으로 가져온다. Fine에서 옮겨 왔다(11/01) — Fine 때는 sm을
/// CLI로 불렀지만 이제 sm 안이라 같은 일을 직접 한다.
/// - `sm:<이름>`: sm 세션. 그 세션이 보이는 곳(sm 패널, 또는 Fine 탭)을 연다(`session.reveal`).
/// - `fine:<탭>`: Fine의 직접 모드 탭. Fine이 그 탭을 고른다.
/// - `%12` 같은 tmux 칸: 브리지가 그 칸을 고르고, 그 tmux 세션의 sm 워크스페이스를 고른다.
@MainActor
enum AttentionRouter {
    static func open(_ item: AttentionItem) async throws {
        guard !item.source.isEmpty else { throw AttentionError("notification has no return address") }
        let localHost = PeerDirectory.shared.localHostName
        let host = item.host == "local" ? localHost : item.host
        if item.source.hasPrefix("sm:") {
            try await control("session.reveal", ["target": String(item.source.dropFirst(3)) + "@" + host])
            return
        }
        if item.source.hasPrefix("fine:") {
            guard host == localHost else { throw AttentionError("a Fine tab on another machine cannot be opened here") }
            _ = try await run(FineControl.cli, ["tab", "select", String(item.source.dropFirst(5))])
            return
        }
        // A tmux pane is reached through tmux-bridge, which only tmux setups have; seol's sessions take the paths above.
        let bridge = ProcessInfo.processInfo.environment["FINE_BRIDGE_BIN"] ?? NSHomeDirectory() + "/.smux/bin/tmux-bridge"
        guard FileManager.default.isExecutableFile(atPath: bridge) else {
            throw AttentionError("this notice came from a tmux pane, and opening one needs tmux-bridge (\(bridge))")
        }
        let output = try await run(bridge, ["focus", item.address, "--fingerprint", item.fingerprint])
        guard let location = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let session = location["session"] as? String else { return }
        // 같은 이름의 다른 기기 세션으로 튀지 않게 기기와 세션을 함께 맞춘다.
        let rows = try await control("ws.list", [:]) as? [[String: Any]] ?? []
        let remote = host == localHost ? "" : item.host
        guard let row = rows.first(where: {
            ($0["tmuxSession"] as? String) == session && ($0["remoteHost"] as? String ?? "") == remote
        }), let id = row["id"] as? String else { throw AttentionError("no sm workspace for this session") }
        try await control("ws.select", ["ws": id])
    }

    @discardableResult
    private static func control(_ command: String, _ args: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            ControlCommands.handle(ControlRequest(command: command, args: args)) { response in
                switch response {
                case .ok(let result): continuation.resume(returning: result)
                case .error(let message): continuation.resume(throwing: AttentionError(message))
                }
            }
        }
    }

    /// 다른 프로그램을 띄워 출력을 받는다. 화면 스레드를 막지 않고, 15초 넘게 걸리면 끊는다.
    static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    guard process.terminationStatus == 0 else { throw AttentionError("source unavailable") }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
