import Foundation

/// sm의 세션 층(`~/.smux/bin/sm-session`)을 부르는 곳. 세션을 띄우고 살려 두고 되살리는 일과
/// 배치(탭·패널)를 바꾸는 일은 모두 이 명령으로만 한다 — 앱도 에이전트도 같은 길을 쓴다(10/31 계약).
/// 앱은 화면 층이라 결과를 그릴 뿐이다.
enum SessionLayer {
    static var executable: String { NSHomeDirectory() + "/.smux/bin/sm-session" }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// 명령 하나를 뒤에서 돌리고 표준 출력을 돌려준다. 실패하면 표준 오류의 마지막 줄을 담는다.
    static func run(_ arguments: [String], completion: @escaping (Result<Data, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSync(arguments)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func runSync(_ arguments: [String]) -> Result<Data, Failure> {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(Failure(message: "세션 층(~/.smux/bin/sm-session)이 이 기기에 없습니다"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // Finder에서 뜬 앱의 PATH에는 ~/.smux/bin과 Homebrew가 없다. sm-session은 ssh·ccv·ccx를 이름으로 부른다.
        let extra = [NSHomeDirectory() + "/.smux/bin", NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure(Failure(message: "sm-session 실행 실패: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let line = errorText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "종료 코드 \(process.terminationStatus)"
            return .failure(Failure(message: line))
        }
        return .success(data)
    }

    /// 새 에이전트를 띄우는 인자. 모델·effort는 엔진의 래퍼(ccv·ccx)가 받는 모양으로 넘긴다.
    static func spawnArguments(_ spec: AgentLaunchSpec, pane: String?, workingDirectory: String,
                               host: String? = nil) -> [String] {
        var args = ["spawn", spec.name, "--kind", spec.engine.rawValue, "--cwd", workingDirectory]
        if let host { args += ["--host", host] }
        if let pane { args += ["--pane", pane] }
        args.append("--")
        switch spec.engine {
        case .claude:
            args += ["--model", spec.modelID, "--effort", spec.effort.rawValue]
        case .codex:
            args += ["-m", spec.modelID, "-c", "model_reasoning_effort=\(spec.effort.rawValue)"]
        }
        return args
    }

    /// 이 워크스페이스 폴더 아래에서 패널 없이 도는(또는 끝난) 세션 — 고르는 상자의 "가져오기" 목록.
    static func backgroundSessions(underFolder folder: String, host: String? = nil) -> [AgentPickerSession] {
        var args = ["ls", "--json"]
        if let host { args += ["--host", host] }
        guard case .success(let data) = runSync(args),
              let listing = try? JSONDecoder().decode(SessionListing.self, from: data) else { return [] }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return listing.sessions
            .filter { ($0.cwd == folder || ($0.cwd ?? "").hasPrefix(prefix)) && $0.pane == nil }
            .compactMap(\.pickerSession)
    }

    struct SessionListing: Decodable {
        let sessions: [Row]

        struct Row: Decodable {
            let name: String
            let kind: String?
            let status: String?
            let cwd: String?
            let pane: String?
            let lastActive: Double?

            enum CodingKeys: String, CodingKey {
                case name, kind, status, cwd, pane
                case lastActive = "last_active"
            }

            var pickerSession: AgentPickerSession? {
                guard let engine = AgentEngine(rawValue: kind ?? "") else { return nil }
                let state: AgentPickerSession.Status = switch status {
                case "running": .running
                case "dead": .dead
                default: .ended
                }
                return AgentPickerSession(name: name, engine: engine, status: state,
                                          lastActive: lastActive.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }
}

/// 고르는 상자의 모델 목록.
enum AgentModelCatalog {
    /// Claude 모델은 설치된 claude 실행 파일에서 뽑는다(Quick과 같은 출처). 실행 파일을 훑느라 느릴 수 있어
    /// 뒤에서 부른다. 상자는 그동안 Quick의 기본 목록으로 먼저 뜬다.
    static func claude() -> [AgentModelChoice] {
        ClaudeCLIModelDiscovery.discover().map(choice)
    }

    static func claudeFallback() -> [AgentModelChoice] {
        QuickModelCatalog.fallbackModels.map(choice)
    }

    private static func choice(_ model: QuickModelOption) -> AgentModelChoice {
        AgentModelChoice(id: model.id, name: model.displayName, efforts: model.supportedEfforts, defaultEffort: .high)
    }

    /// Codex 모델은 Codex가 받아 둔 목록(~/.codex/models_cache.json)에서 보이는 것만.
    static func codex(cache: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/models_cache.json")) -> [AgentModelChoice] {
        struct Cache: Decodable {
            struct Model: Decodable {
                struct Level: Decodable { let effort: String }
                let slug: String
                let display_name: String
                let visibility: String?
                let default_reasoning_level: String?
                let supported_reasoning_levels: [Level]?
            }
            let models: [Model]
        }
        guard let data = try? Data(contentsOf: cache),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return decoded.models.filter { ($0.visibility ?? "list") == "list" }.map { model in
            AgentModelChoice(id: model.slug, name: model.display_name,
                             efforts: (model.supported_reasoning_levels ?? []).compactMap { QuickEffort(rawValue: $0.effort) },
                             defaultEffort: model.default_reasoning_level.flatMap(QuickEffort.init(rawValue:)))
        }
    }
}
