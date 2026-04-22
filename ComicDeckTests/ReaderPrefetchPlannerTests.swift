import XCTest
@testable import ComicDeck

@MainActor
final class ReaderPrefetchPlannerTests: XCTestCase {
    func testForwardDirectionPrefersAheadPagesFirst() {
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 5, total: 12, distance: 3, direction: 1),
            [6, 4, 7, 3, 8, 2]
        )
    }

    func testBackwardDirectionPrefersPreviousPagesFirst() {
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 5, total: 12, distance: 3, direction: -1),
            [4, 6, 3, 7, 2, 8]
        )
    }

    func testIdleDirectionStillPrefersForwardPagesFirst() {
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 2, total: 5, distance: 2, direction: 0),
            [3, 1, 4, 0]
        )
    }

    func testPlannerClampsToAvailableBounds() {
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 0, total: 3, distance: 4, direction: -1),
            [1, 2]
        )
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 2, total: 3, distance: 4, direction: 1),
            [1, 0]
        )
    }

    func testPlannerReturnsEmptyIndexesForEmptyOrInvalidInputs() {
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 0, total: 0, distance: 3, direction: 1),
            []
        )
        XCTAssertEqual(
            ReaderPrefetchPlanner.preferredPrefetchIndexes(current: 0, total: 3, distance: 0, direction: 1),
            []
        )
    }
}
