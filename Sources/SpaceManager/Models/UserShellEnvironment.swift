import Foundation

/// 사용자의 대화형 셸이 만드는 PATH. 패널에 이것을 넘긴다.
///
/// 앱이 Finder·Dock·로그인 항목으로 뜨면 PATH가 시스템 기본값뿐이고, 패널이 명령을 돌리는 로그인 셸(`zsh -lc`)은
/// 사용자의 PATH가 들어 있는 대화형 설정(.zshrc)을 읽지 않는다. 그래서 패널 안의 세션 층이 멈춘 에이전트를
/// 이어서 띄우려다 `ccv`를 찾지 못했다(11/01, 인체안내서 패널에 Traceback). 터미널 앱들이 하는 대로 사용자 셸을
/// 한 번 대화형으로 띄워 PATH를 받아 둔다(이 맥에서 0.05초). 못 받으면(설정이 멈추는 등) 흔한 자리를 덧붙인다.
enum UserShellEnvironment {
    static let path: String = resolve() ?? fallback

    static var fallback: String {
        let home = NSHomeDirectory()
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = [home + "/bin", home + "/.local/bin", home + "/.smux/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return (extra + [inherited]).joined(separator: ":")
    }

    static func resolve(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                        timeout: TimeInterval = 3) -> String? {
        let marker = "__SM_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        // 앱이 물려받은 것(에이전트 세션 변수 등) 없이, 사람이 새 터미널을 연 것처럼.
        var env = ["HOME": NSHomeDirectory(), "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = String(line.dropFirst(marker.count))
        return path.isEmpty ? nil : path
    }
}
