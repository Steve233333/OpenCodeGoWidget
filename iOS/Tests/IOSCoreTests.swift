import XCTest
@testable import OpenCodeGoIOS

final class IOSCoreTests: XCTestCase {
    func testStoredSessionRoundTrip() throws {
        let session = IOSStoredSession(
            consoleSession: "st_test",
            authCookie: nil,
            workspaceID: "wrk_test_workspace",
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(IOSStoredSession.self, from: data), session)
        XCTAssertNil(session.authCookie)
    }

    func testWorkspaceExtractionFromConsoleURL() {
        XCTAssertEqual(
            OpenCodeKeyFetcher.workspaceID(
                fromURL: "https://opencode.ai/console/wrk_01KT9VX0KZCD5SYNXH8D3EYJD8/go"
            ),
            "wrk_01KT9VX0KZCD5SYNXH8D3EYJD8"
        )
    }

    func testSnapshotPerKeyFiltering() {
        let snapshot = WidgetSnapshot(
            rolling: 10,
            weekly: 20,
            monthly: 30,
            rollingReset: Date(),
            weeklyReset: Date(),
            monthlyReset: Date(),
            costTotal: 0.3,
            costEntries: ["deepseek-v4.1-flash": 0.3],
            dailyCosts: [
                DailyCost(date: "2026-11-01", entries: ["deepseek-v4.1-flash": 0.3])
            ],
            availableKeys: [
                ApiKeyInfo(id: "keyA", displayName: "方泽恩 - 方泽恩")
            ],
            dailyByKey: [
                "keyA": [
                    DailyCost(date: "2026-11-01", entries: ["deepseek-v4.1-flash": 0.3])
                ]
            ],
            costEntriesByKey: ["keyA": ["deepseek-v4.1-flash": 0.3]],
            costTotalByKey: ["keyA": 0.3],
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.filteredDaily(for: "keyA").first?.total, 0.3)
        XCTAssertEqual(snapshot.filteredCostTotal(for: "missing"), 0)
    }

    func testDashboardPeriodUsesSelectedKeyAndAlignment() {
        let calendar = BillingCycle.calendar
        let reset = calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 18
        ))!
        let allDays = [
            DailyCost(date: "2026-10-20", entries: ["model-a": 1]),
            DailyCost(date: "2026-11-01", entries: ["model-a": 2]),
            DailyCost(date: "2026-11-10", entries: ["model-a": 3]),
            DailyCost(date: "2026-11-18", entries: ["model-a": 4]),
        ]
        let snapshot = WidgetSnapshot(
            rolling: 0,
            weekly: 0,
            monthly: 0,
            rollingReset: Date(),
            weeklyReset: Date(),
            monthlyReset: reset,
            costTotal: 0,
            costEntries: [:],
            dailyCosts: allDays,
            dailyByKey: ["keyA": allDays],
            updatedAt: Date()
        )

        let billing = IOSDashboardData.periodDaily(
            snapshot: snapshot,
            selectedKeyID: "keyA",
            alignment: .billing
        )
        let calendarMonth = IOSDashboardData.periodDaily(
            snapshot: snapshot,
            selectedKeyID: "keyA",
            alignment: .calendar
        )

        XCTAssertEqual(billing.map(\.date), ["2026-10-20", "2026-11-01", "2026-11-10"])
        XCTAssertEqual(IOSDashboardData.total(billing), 6, accuracy: 0.000_001)
        XCTAssertEqual(calendarMonth.map(\.date), ["2026-11-01", "2026-11-10", "2026-11-18"])
        XCTAssertEqual(IOSDashboardData.total(calendarMonth), 9, accuracy: 0.000_001)
    }

    func testFoldedModelTotalsPreserveTopModelsAndOther() {
        let daily = [
            DailyCost(
                date: "2026-11-01",
                entries: [
                    "model-a": 5,
                    "model-b": 4,
                    "model-c": 3,
                    "model-d": 2,
                ]
            ),
            DailyCost(
                date: "2026-11-02",
                entries: [
                    "model-b": 1,
                    "model-e": 1,
                ]
            ),
        ]
        let folded = IOSDashboardData.foldedModelTotals(daily, topCount: 2)

        XCTAssertEqual(folded.count, 3)
        XCTAssertEqual(folded[0], IOSModelAmount(model: "model-a", amount: 5))
        XCTAssertEqual(folded[1], IOSModelAmount(model: "model-b", amount: 5))
        XCTAssertEqual(folded[2], IOSModelAmount(model: ModelPalette.otherName, amount: 6))
    }

    func testSelectedKeyIsRemovedWhenDirectoryChanges() {
        let state = KeyDirectoryState(
            status: .live,
            keys: [ApiKeyInfo(id: "new", displayName: "新 Key")],
            checkedAt: Date(),
            sessionFingerprint: "fp",
            detail: nil
        )
        XCTAssertTrue(KeyDirectoryStore.selectedKeyIsAvailable("new", in: state))
        XCTAssertFalse(KeyDirectoryStore.selectedKeyIsAvailable("old", in: state))
    }

    func testIOSPlatformIdentities() {
        XCTAssertEqual(PlatformConfig.appBundleID, "com.steve233.opencodego.ios")
        XCTAssertEqual(PlatformConfig.appGroupID, "group.com.steve233.opencodego.ios")
        XCTAssertEqual(PlatformConfig.backgroundRefreshID, "com.steve233.opencodego.ios.refresh")
    }

    func testAppGroupRoundTrip() {
        XCTAssertTrue(IOSSessionStore.verifyAppGroupRoundTrip())
    }
}
