import XCTest
@testable import AccountCore

final class DisplayTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testCountdownUsesDaysHoursAndMinutes() {
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 + 2 * 86400 + 3 * 3600 + 12 * 60, now: now), "2天3小时12分")
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 + 3600, now: now), "1小时0分")
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 + 86400, now: now), "1天0小时0分")
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 + 60, now: now), "1分")
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 + 59, now: now), "不足1分钟")
    }
    func testElapsedDoesNotInventQuotaReset() {
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970, now: now), "待刷新")
        XCTAssertEqual(DateText.remaining(now.timeIntervalSince1970 - 60, now: now, elapsed: "已到期·待更新"), "已到期·待更新")
        XCTAssertEqual(DateText.remaining(.infinity, now: now), "待确认")
    }
    func testSameSnapshotCountsDownWithoutNetworkRefresh() {
        let deadline = now.timeIntervalSince1970 + 120
        XCTAssertEqual(DateText.remaining(deadline, now: now), "2分")
        XCTAssertEqual(DateText.remaining(deadline, now: now.addingTimeInterval(60)), "1分")
    }
    func testPremiumMappingAndFreshResponsePrecedence() {
        XCTAssertEqual(PlanLabel.display(current: nil, stored: "self_serve_business_prolite"), "Business Premium")
        XCTAssertEqual(PlanLabel.display(current: "self_serve_business_prolite", stored: "plus"), "Business Premium")
        XCTAssertEqual(PlanLabel.display(current: "future_unknown_plan", stored: "plus"), "订阅待确认")
        XCTAssertEqual(PlanLabel.display(current: nil, stored: "self_serve_business_usage_based"), "Business")
    }
    func testCardCountdownPreservesAuthoritativeCountAfterExpiry() throws {
        let d = Data("""
        {"availableCount":1,"credits":[{"id":"one","status":"available","resetType":"codexRateLimits","expiresAt":1800000120}]}
        """.utf8)
        let cards = try JSONDecoder().decode(CardSummary.self, from: d)
        XCTAssertEqual(cards.expiryLabel(now: now), "2分")
        XCTAssertEqual(cards.expiryLabel(now: now.addingTimeInterval(180)), "已到期·待更新")
        XCTAssertEqual(cards.availableCount, 1)
    }
}
