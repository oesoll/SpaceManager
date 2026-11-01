import XCTest
@testable import SpaceManager

/// 보이는 패널만 attach한다(SEOL 11/01, briefs/sleep-wake-ux.md). 가려진 세션 패널은 마지막으로 보인 지
/// 10분이 지나면 attach를 내린다 — 세션 층은 보는 창이 하나도 없는 워크스페이스만 재우기 때문이다. 바로 내리지
/// 않는 것은 탭·워크스페이스를 오갈 때 다시 붙느라 늦지 않게.
final class ParkHiddenPanesTests: XCTestCase {
    func testOnlyHiddenAttachedPanesPastTheGraceArePutDown() {
        let now = Date(timeIntervalSince1970: 10_000)
        let attached: Set<String> = ["ws@mac/a", "ws@mac/b", "ws@mac/c", "ws@mac/d"]
        let lastDisplayed: [String: Date] = [
            "ws@mac/b": now.addingTimeInterval(-60),        // 1분 전에 봄: 아직 둔다
            "ws@mac/c": now.addingTimeInterval(-11 * 60),   // 11분 전: 내린다
        ]
        let park = LayoutTerminals.toPark(attached: attached, displayed: ["ws@mac/a"], lastDisplayed: lastDisplayed,
                                          now: now, grace: LayoutTerminals.parkAfter)
        // a는 지금 보이고, b는 방금 봤고, c는 오래됐고, d는 이번 실행에서 한 번도 보이지 않았다(앱이 막 떴다 등).
        XCTAssertEqual(park, ["ws@mac/c", "ws@mac/d"])
    }

    func testNothingAttachedNothingToPutDown() {
        XCTAssertEqual(LayoutTerminals.toPark(attached: [], displayed: [], lastDisplayed: [:], now: Date(), grace: 600), [])
    }
}
