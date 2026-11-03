// Fine에서 노치와 함께 옮겨 온 시험(11/01). 저장소 규칙·노치 기하·묶음은 Fine 때와 같아야 한다.
import Testing
import Foundation
import AppKit
@testable import SpaceManager

@MainActor
struct AttentionTests {
    func args(_ state: String = "waiting", key: String = "build", host: String = "mac") -> [String: Any] {
        ["host": host, "source": "%42", "key": key, "title": "결제 리팩터링", "message": "이 방향으로 진행할까요?", "state": state]
    }

    @Test func notchMatchesReportedSafeRegionsIncludingOffsetDisplays() {
        let display = AttentionDisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), safeTop: 32,
            left: CGRect(x: 0, y: 924, width: 645.5, height: 32),
            right: CGRect(x: 824.5, y: 924, width: 645.5, height: 32))
        #expect(display.housing?.size == CGSize(width: 179, height: 32))
        #expect(display.badgeFrame.size == CGSize(width: 22, height: 22))
        #expect(display.badgeFrame.maxX == 639.5)
        #expect(!display.badgeFrame.intersects(display.housing!))
        #expect(display.reaches(CGPoint(x: 735, y: 940), display.hoverFrame))
        // A cursor pinned to the top edge reports maxY itself; it must still count.
        #expect(display.reaches(CGPoint(x: 735, y: 956), display.hoverFrame))
        #expect(display.reaches(CGPoint(x: 647, y: 956), display.hoverFrame))
        #expect(!display.reaches(CGPoint(x: 735, y: 957), display.hoverFrame), "a display above is not the notch")
        #expect(!display.reaches(CGPoint(x: 735, y: 919), display.hoverFrame))
        #expect(!display.reaches(CGPoint(x: 637, y: 940), display.hoverFrame))
        let expanded = display.frame(size: CGSize(width: 420, height: 300))
        #expect(expanded.maxY == 956)
        #expect(expanded.midX == display.housing?.midX)
        #expect(expanded.width == 420 + 2 * AttentionDisplayGeometry.shoulder)
        #expect(display.contentWidth == 291)
        #expect(display.restingSize == display.housing!.size)
        let offset = AttentionDisplayGeometry(frame: CGRect(x: -1800, y: 400, width: 1600, height: 1000), safeTop: 28,
            left: CGRect(x: -1800, y: 1372, width: 705, height: 28),
            right: CGRect(x: -920, y: 1372, width: 720, height: 28))
        #expect(offset.housing?.width == 175)
        #expect(offset.centerX == -1007.5)
        #expect(offset.frame(size: CGSize(width: 420, height: 300)).maxY == 1400)
        let external = AttentionDisplayGeometry(frame: CGRect(x: 1470, y: 0, width: 1920, height: 1080),
                                               safeTop: 0, left: nil, right: nil)
        #expect(external.housing == nil)
        #expect(external.centerX == 2430)
    }

    @Test func sameTaskUpdatesAndOnlyChangedQuestionsAlert() throws {
        let store = AttentionStore()
        var alerts = 0
        store.onAttention = { alerts += 1 }
        let item = try store.post(args())
        #expect(store.waitingCount == 1)
        try store.post(args())
        #expect(alerts == 1)
        let updated = try store.post(args("working"))
        #expect(item.id == updated.id)
        #expect(store.items.count == 1 && store.waitingCount == 0 && store.workingCount == 1)
        try store.post(args("blocked"))
        #expect(alerts == 2)
        try store.post(args("done"))
        #expect(store.waitingCount == 0)
    }

    @Test func hostAndSenderSeparateIdenticalTaskKeys() throws {
        let store = AttentionStore()
        try store.post(args(host: "mac"))
        try store.post(args(host: "arch"))
        var other = args(); other["source"] = "%43"
        try store.post(other)
        #expect(Set(store.items.map(\.id)).count == 3)
    }

    @Test func resumedConversationReplacesItsOldAddressButTaskKeysDoNot() throws {
        let store = AttentionStore()
        let session = "claude:4116c17b-5f60-451c-8512-6dc69beaf63c"
        var before = args("working", key: session); before["source"] = "fine:e8a8b4f9-3106-479e-a9c9-39e8bc76e4e4"
        var after = args("waiting", key: session); after["source"] = "fine:038c106b-45ac-4c8a-9e7a-e56de175d2a2"
        try store.post(before)
        try store.post(after)
        #expect(store.items.count == 1 && store.items[0].source == "fine:038c106b-45ac-4c8a-9e7a-e56de175d2a2")
        var arch = after; arch["host"] = "arch"
        try store.post(arch)
        #expect(store.items.count == 2, "the same ID on another host is another conversation")
    }

    @Test func groupsByWorkspaceWithFineAndHostFallbacks() throws {
        let store = AttentionStore()
        var habit = args("working", key: "codex:01a11fee-2748-7a01-0000-000000000001", host: "arch")
        habit["workspace"] = "Habitrend"
        var habitQuestion = args("waiting", key: "claude:bb8f8469-85c8-45d8-0000-000000000002", host: "arch")
        habitQuestion["workspace"] = "Habitrend"; habitQuestion["source"] = "%9"
        var fineTab = args("working", key: "claude:fb1d30e0-49e5-4446-0000-000000000003")
        fineTab["source"] = "fine:bc1e3acd-2449-4f29-991c-e8212880927e"
        let legacy = args("error", key: "old", host: "arch")
        for event in [habit, habitQuestion, fineTab, legacy] { try store.post(event) }
        #expect(store.items.first { $0.key == "old" }?.workspace == nil)
        let notch = AttentionNotch(store: store)
        let groups = notch.groups
        #expect(groups.map(\.name) == ["arch", "Habitrend", "Fine"], "the most urgent group leads")
        #expect(groups[1].items.map(\.state) == [.waiting, .working], "questions lead inside a workspace")
        #expect(notch.listHeight > 0)
    }

    @Test func quietWorkNeverBecomesDoneOrAQuestion() throws {
        let store = AttentionStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.post(args("working"), now: now)
        try store.post(args("waiting", key: "question"), now: now)
        try store.post(args("done", key: "finished"), now: now)
        try store.expire(now: now.addingTimeInterval(AttentionStore.workingLease + 1))
        #expect(store.items.count == 2)
        #expect(store.items.first { $0.key == "build" }?.state == .unknown)
        #expect(store.items.first { $0.key == "question" }?.state == .waiting)
    }

    @Test func persistsPendingQuestionsAndDismissal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("attention.json")
        let store = AttentionStore(file: file)
        let item = try store.post(args())
        let restored = AttentionStore(file: file)
        #expect(restored.items == store.items)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try restored.dismiss(id: item.id)
        #expect(AttentionStore(file: file).items.isEmpty)
    }

    @Test func rejectsMalformedInputAndDoesNotLosePendingItems() throws {
        let store = AttentionStore()
        for (name, value) in [("host", "mac; injected"), ("source", "fine:not-a-uuid"),
                              ("state", "invented"), ("message", String(repeating: "x", count: 8001)), ("key", "")] {
            var invalid = args(); invalid[name] = value
            #expect(throws: AttentionError.self) { try store.post(invalid) }
        }
        #expect(store.items.isEmpty)
        for index in 0..<AttentionStore.capacity { try store.post(args(key: String(index))) }
        #expect(throws: AttentionError.self) { try store.post(args(key: "overflow")) }
        #expect(store.items.count == AttentionStore.capacity)
        try store.post(args("working", key: "0"))
        #expect(store.items.count == AttentionStore.capacity)
    }

    @Test func failedPersistenceDoesNotAcknowledgeAnUndeliveredNotification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttentionStore(file: directory)
        #expect(throws: (any Error).self) { try store.post(args()) }
        #expect(store.items.isEmpty)
    }

    // 11/02: 패널의 쉼 알림이 89개 쌓였다(키가 앱 객체 UUID, 아무도 그 칸에 안 침). 쉼 알림은 에이전트가 다시 일하거나
    // 끝나면 걷히고, 반나절이면 사라지며, 같은 알림이 곧 다시 오면 파일을 다시 쓰지 않는다. 질문 알림은 그대로다.
    @Test func terminalPingsClearThemselvesButQuestionsStay() throws {
        let store = AttentionStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func ping(_ name: String, host: String = "mac") -> [String: Any] {
            ["host": host, "source": "sm:" + name, "key": "terminal:\(name)@\(host)", "title": name,
             "message": "Claude is waiting for your input", "state": "waiting"]
        }
        try store.post(ping("w1"), now: t0)
        try store.post(ping("w2"), now: t0)
        try store.post(ping("gone1"), now: t0)
        try store.post(["host": "mac", "source": "sm:w1", "key": "deploy-q", "title": "배포할까요?", "state": "waiting"], now: t0)
        // the same ping again within a minute: same item, same time (no rewrite)
        let again = try store.post(ping("w1"), now: t0.addingTimeInterval(20))
        #expect(again.updatedAt == t0)
        func agent(_ name: String, _ state: PeerState, since: Date) -> PeerAgent {
            PeerAgent(id: name + "-id", name: name, host: "mac", target: "sm:" + name, state: state, since: since)
        }
        store.settle(with: [agent("w1", .working, since: t0.addingTimeInterval(5)),
                            agent("w2", .idle, since: t0.addingTimeInterval(5)),
                            agent("gone1", .gone, since: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(10))
        let byKey = Dictionary(uniqueKeysWithValues: store.items.map { ($0.key, $0) })
        #expect(byKey["terminal:w1@mac"]?.state == .done, "working again after the ping: no longer waiting")
        #expect(byKey["terminal:w2@mac"]?.state == .waiting, "still idle: still waiting")
        #expect(byKey["terminal:gone1@mac"] == nil, "an ended agent's ping goes")
        #expect(byKey["deploy-q"]?.state == .waiting, "a question is never settled by peer state")
        // working that started before the ping does not count
        try store.post(ping("w3"), now: t0)
        store.settle(with: [agent("w3", .working, since: t0.addingTimeInterval(-60))], now: t0.addingTimeInterval(10))
        #expect(store.items.first { $0.key == "terminal:w3@mac" }?.state == .waiting)
        // a hook's session notice from an sm agent that ended goes too
        try store.post(["host": "mac", "source": "sm:cx1", "key": "codex:01a19707-e90e-7442-9b33-f4b441000000", "title": "tmp · codex",
                        "state": "waiting"], now: t0)
        store.settle(with: [agent("cx1", .gone, since: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(10))
        #expect(!store.items.contains { $0.key.hasPrefix("codex:") })
        // half a day later the pings are gone, the question stays
        try store.expire(now: t0.addingTimeInterval(AttentionStore.pingLifetime + 1))
        #expect(store.items.map(\.key) == ["deploy-q"])
    }

    @Test func oldPerObjectPaneKeysAreDroppedOnceAtStart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = AttentionStore(file: file)
        try first.post(["host": "mac", "source": "sm:w1", "key": "terminal:" + UUID().uuidString.lowercased(), "title": "w1", "state": "waiting"])
        try first.post(["host": "mac", "source": "sm:w1", "key": "terminal:w1@mac", "title": "w1", "state": "waiting"])
        let fineKey = "terminal:" + UUID().uuidString.lowercased()
        try first.post(["host": "local", "source": "fine:" + UUID().uuidString, "key": fineKey, "title": "fine", "state": "waiting"])
        let second = AttentionStore(file: file)
        second.start()
        #expect(Set(second.items.map(\.key)) == ["terminal:w1@mac", fineKey], "Fine's own tab keys are stable and stay")
    }
}
