import AppKit
import QuartzCore

/// 앱이 자기 창을 찍고, 메인 스레드가 프레임을 놓치는지 잰다 — `sm capture`, `sm perf`.
///
/// 앱은 자기 창을 화면 기록 권한 없이 찍을 수 있다. 에이전트가 도는 셸에는 그 권한이 없어서
/// `screencapture`가 막혀 있었고(10/31), 그래서 SEOL이 짚은 화면 문제를 에이전트가 직접 볼 길이 없었다.
/// 이 둘이 있으면 "페이드가 끊긴다", "포커스 전환이 버벅인다" 같은 말을 숫자와 그림으로 확인할 수 있다.
enum WindowProbe {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage는 macOS 15 SDK에서 Swift에 막혀 있어 심볼로 부른다(캡처 테스트와 같다).
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// 창 하나(다른 창에 가려져 있어도 그 창의 내용). `rect`는 창 왼쪽 위 기준 포인트, nil이면 창 전체.
    static func image(windowNumber: Int, screenRect: CGRect?) -> CGImage? {
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        return createImage?(screenRect ?? .null, optionIncludingWindow, UInt32(windowNumber), boundsIgnoreFraming)?
            .takeRetainedValue()
    }

    /// 창 안의 사각형(왼쪽 위 기준) → CoreGraphics 전역 좌표(주 화면 왼쪽 위 기준).
    @MainActor
    static func screenRect(_ rect: CGRect, in window: NSWindow) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        return CGRect(x: window.frame.minX + rect.minX, y: primaryHeight - window.frame.maxY + rect.minY,
                      width: rect.width, height: rect.height)
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ControlCommands.CommandError(message: "png encode failed")
        }
        try data.write(to: url)
    }

    /// 평균 색(0–255). 테두리를 가로지르는 가는 띠를 연달아 찍으면 페이드가 몇 장면으로 그려졌는지 보인다.
    static func meanColor(_ image: CGImage) -> [Double] {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return [0, 0, 0] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [0, 0, 0] }
        var sum = [0.0, 0.0, 0.0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum[0] += Double(pixels[index]); sum[1] += Double(pixels[index + 1]); sum[2] += Double(pixels[index + 2])
        }
        let count = Double(width * height)
        return sum.map { ($0 / count * 10).rounded() / 10 }
    }

    /// 같은 자리를 `count`번, `every`초 간격으로 찍는다(백그라운드 스레드 — 메인 스레드를 막으면 재려는
    /// 바로 그것을 망친다). 결과는 시작부터의 밀리초와 평균 색.
    static func burst(windowNumber: Int, screenRect: CGRect, count: Int, every: TimeInterval, folder: String?,
                      start: CFTimeInterval? = nil, duration: TimeInterval? = nil,
                      completion: @escaping ([[String: Any]]) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let start = start ?? CACurrentMediaTime()
            var shots: [(Double, CGImage?)] = []
            let first = CACurrentMediaTime()
            for index in 0..<count {
                // 큰 사각형은 한 장에 수 ms가 걸린다. 정해진 시간이 지나면 장수를 다 못 채워도 멈춘다.
                if let duration, CACurrentMediaTime() - first > duration { break }
                let due = first + every * Double(index)
                let wait = due - CACurrentMediaTime()
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                let at = CACurrentMediaTime()
                shots.append(((at - start) * 1000, image(windowNumber: windowNumber, screenRect: screenRect)))
            }
            var rows: [[String: Any]] = []
            for (index, (at, shot)) in shots.enumerated() {
                var row: [String: Any] = ["t": (at * 10).rounded() / 10, "rgb": shot.map(meanColor) ?? []]
                if let folder, let shot {
                    let path = (folder as NSString).appendingPathComponent(String(format: "%03d.png", index))
                    if (try? writePNG(shot, to: path)) != nil { row["file"] = path }
                }
                rows.append(row)
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }
}

/// 창의 화면 주사율대로 메인 스레드에서 한 번씩 불린다. 콜백 사이가 한 프레임보다 길면 그만큼 메인
/// 스레드가 막혀 프레임을 놓친 것이다 — SwiftUI 애니메이션과 입력 처리가 그 동안 멈춘다.
@MainActor
final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var start: CFTimeInterval = 0
    private static var running: [FrameProbe] = []

    /// `action`이 있으면 0.3초 뒤 메인 스레드에서 한 번 부른다(탭·포커스 전환 등, 사람이 누르는 것과 같은 길).
    /// `watch`가 있으면 그 사각형을 같은 시간축에서 연달아 찍어, 동작 뒤 화면이 처음 바뀐 시각을 낸다.
    static func run(window: NSWindow, seconds: TimeInterval, action: (() -> Void)? = nil, watch: CGRect? = nil,
                    completion: @escaping ([String: Any]) -> Void) {
        let probe = FrameProbe()
        running.append(probe)
        let link = window.displayLink(target: probe, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        probe.link = link
        probe.start = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        var shots: [[String: Any]]?
        let group = DispatchGroup()
        if let watch {
            group.enter()
            let every = 0.004
            WindowProbe.burst(windowNumber: window.windowNumber, screenRect: watch, count: Int(seconds / every),
                              every: every, folder: nil, start: probe.start, duration: seconds) { rows in
                shots = rows
                group.leave()
            }
        }
        if let action {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                probe.actionAt = (CACurrentMediaTime() - probe.start) * 1000
                action()
                probe.actionDone = (CACurrentMediaTime() - probe.start) * 1000
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            link.invalidate()
            group.notify(queue: .main) {
                running.removeAll { $0 === probe }
                var report = probe.report(hz: Double(window.screen?.maximumFramesPerSecond ?? 60))
                if let shots { report.merge(probe.changes(in: shots)) { $1 } }
                completion(report)
            }
        }
    }

    private var actionAt: Double?
    private var actionDone: Double?

    /// 동작 전 마지막 장면과 달라진 첫 장면, 그리고 더 이상 바뀌지 않게 된 장면(페이드가 끝난 때).
    private func changes(in shots: [[String: Any]]) -> [String: Any] {
        func rgb(_ row: [String: Any]) -> [Double] { row["rgb"] as? [Double] ?? [] }
        func t(_ row: [String: Any]) -> Double { row["t"] as? Double ?? 0 }
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == 3, b.count == 3 else { return 0 }
            return zip(a, b).map { abs($0 - $1) }.max() ?? 0
        }
        let at = actionAt ?? 0
        guard let base = shots.last(where: { t($0) < at }) else { return ["shots": shots.count] }
        let after = shots.filter { t($0) >= at }
        var out: [String: Any] = ["shots": shots.count,
                                  "shot_interval": shots.count > 1 ? ((t(shots.last!) - t(shots.first!)) / Double(shots.count - 1) * 10).rounded() / 10 : 0]
        if let first = after.first(where: { distance(rgb($0), rgb(base)) > 1.5 }) {
            out["visible_after"] = ((t(first) - at) * 10).rounded() / 10
            // 마지막으로 값이 움직인 장면 — 그 뒤로는 그대로다.
            var settled = first
            var previous = rgb(first)
            var steps: [[Double]] = []
            for row in after where t(row) >= t(first) {
                let value = rgb(row)
                if distance(value, previous) > 0.5 {
                    settled = row
                    steps.append([((t(row) - at) * 10).rounded() / 10] + value)
                }
                previous = value
            }
            out["settled_after"] = ((t(settled) - at) * 10).rounded() / 10
            out["distinct_frames"] = steps.count + 1
            out["steps"] = Array(steps.prefix(40))
        }
        return out
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
    }

    private func report(hz: Double) -> [String: Any] {
        let frame = 1000 / hz
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        var long: [[String: Double]] = []
        var missed = 0
        for (index, gap) in gaps.enumerated() where gap > frame * 1.5 {
            missed += Int((gap / frame).rounded()) - 1
            long.append(["at": ((stamps[index] - start) * 1000).rounded(), "gap": (gap * 10).rounded() / 10])
        }
        let sorted = gaps.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : (sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 10).rounded() / 10
        }
        var out: [String: Any] = ["hz": hz, "frames": stamps.count, "missed": missed, "p50": percentile(0.5),
                                  "p99": percentile(0.99), "max": ((sorted.last ?? 0) * 10).rounded() / 10,
                                  "long": Array(long.sorted { $0["gap"]! > $1["gap"]! }.prefix(12))]
        if let actionAt, let actionDone {
            out["action_at"] = (actionAt * 10).rounded() / 10
            // 동작 자체(메인 스레드에서 상태를 바꾸는 데)에 걸린 시간. 그 뒤 SwiftUI가 다시 그리는 시간은 long에 보인다.
            out["action_ms"] = ((actionDone - actionAt) * 10).rounded() / 10
        }
        return out
    }
}
