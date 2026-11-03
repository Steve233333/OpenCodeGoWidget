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
