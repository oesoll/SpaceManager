import Foundation

enum AgentEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "낮음"
        case .medium: return "중간"
        case .high: return "높음"
        case .xhigh: return "매우 높음"
        case .max: return "최대"
        case .ultra: return "울트라"
        }
    }
}

struct ClaudeModelOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let supportedEfforts: [AgentEffort]

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case supportedEfforts = "supported_efforts"
    }

    init(
        id: String,
        displayName: String,
        supportedEfforts: [AgentEffort] = [.low, .medium, .high, .xhigh, .max]
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedEfforts = supportedEfforts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        supportedEfforts = try container.decodeIfPresent(
            [AgentEffort].self,
            forKey: .supportedEfforts
        ) ?? [.low, .medium, .high, .xhigh, .max]
    }
}

enum ClaudeCLIModelDiscovery {
    private static let lock = NSLock()
    private static var cached: (path: String, stringsPath: String, signature: FileSignature, models: [ClaudeModelOption])?

    static func discover(executablePath: String? = nil, stringsPath: String = "/usr/bin/strings") -> [ClaudeModelOption] {
        let candidate = executablePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path
        let executable = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
        // Every picker shares discovery; a CLI upgrade invalidates it.
        return lock.withLock {
            guard let signature = FileSignature.read(executable),
                  FileManager.default.isExecutableFile(atPath: stringsPath) else { return [] }
            if let cached, cached.path == executable.path, cached.stringsPath == stringsPath,
               cached.signature == signature { return cached.models }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: stringsPath)
            process.arguments = ["-a", executable.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                var parser = StringTableParser()
                while let data = try pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    parser.consume(data)
                }
                parser.finish()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                cached = (executable.path, stringsPath, signature, parser.models)
                return parser.models
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                return []
            }
        }
    }

    static func parseStringTable(_ output: String) -> [ClaudeModelOption] {
        var parser = StringTableParser()
        parser.consume(Data(output.utf8))
        parser.finish()
        return parser.models
    }

    /// Retain only the adjacent candidate lines, not the CLI's entire string table.
    private struct StringTableParser {
        private var partial = Data()
        private var skipping = false
        private var previous: String?
        private var seen = Set<String>()
        private(set) var models: [ClaudeModelOption] = []

        mutating func consume(_ data: Data) {
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 10) ?? data.endIndex
                if !skipping {
                    if partial.count + end - start <= 4096 { partial.append(data[start..<end]) }
                    else { partial.removeAll(keepingCapacity: true); skipping = true; previous = nil }
                }
                if end < data.endIndex { finish(); start = end + 1 }
                else { break }
            }
        }

        mutating func finish() {
            if !skipping, let raw = String(data: partial, encoding: .utf8), !raw.isEmpty {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let previous, let model = parsePair(idLine: previous, displayLine: line), seen.insert(model.id).inserted {
                    models.append(model)
                }
                previous = line
            }
            partial.removeAll(keepingCapacity: true)
            skipping = false
        }
    }

    private static func parsePair(idLine: String, displayLine: String) -> ClaudeModelOption? {
        let pieces = idLine.split(separator: "-").map(String.init)
        let families: Set<String> = ["fable", "mythos", "opus", "sonnet", "haiku"]
        guard pieces.count >= 3,
              pieces[0] == "claude",
              families.contains(pieces[1]),
              pieces.dropFirst(2).allSatisfy({ Int($0) != nil }) else { return nil }
        let expectedDisplay = "Claude \(pieces[1].capitalized) "
            + pieces.dropFirst(2).joined(separator: ".")
        guard displayLine == expectedDisplay else { return nil }
        return ClaudeModelOption(id: idLine, displayName: displayLine)
    }
}
