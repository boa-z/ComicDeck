import XCTest
import UIKit
@testable import ComicDeck

@MainActor
final class ReaderVerticalCoordinatorTests: XCTestCase {
    func testPlainImageLayoutFallsBackToStablePortraitAspectRatioWhenImageSizeIsUnknown() {
        XCTAssertEqual(ReaderPlainImageLayout.displayAspectRatio(for: nil), 0.7, accuracy: 0.0001)

        let target = ReaderPlainImageLayout.decodeTargetSize(for: 360, imageSize: nil)
        XCTAssertEqual(target.width, 360, accuracy: 0.0001)
        XCTAssertEqual(target.height, 360 / 0.7, accuracy: 0.0001)
    }

    func testPlainImageLayoutUsesImageAspectRatioForDecodeTargetSize() {
        let imageSize = CGSize(width: 1200, height: 1800)

        XCTAssertEqual(ReaderPlainImageLayout.displayAspectRatio(for: imageSize), 1200.0 / 1800.0, accuracy: 0.0001)

        let target = ReaderPlainImageLayout.decodeTargetSize(for: 320, imageSize: imageSize)
        XCTAssertEqual(target.width, 320, accuracy: 0.0001)
        XCTAssertEqual(target.height, 480, accuracy: 0.0001)
    }

    func testPlainImageLayoutIgnoresInvalidImageSizes() {
        XCTAssertEqual(
            ReaderPlainImageLayout.displayAspectRatio(for: CGSize(width: 0, height: 1800)),
            0.7,
            accuracy: 0.0001
        )
    }

    func testPrepareForContentResetsTrackingState() {
        let coordinator = ReaderVerticalCoordinator()
        coordinator.recordPageFrames([
            0: CGRect(x: 0, y: 0, width: 320, height: 480)
        ])
        coordinator.updateViewportHeight(844)
        _ = coordinator.scrollToPage(3, totalPages: 5, at: Date(timeIntervalSince1970: 10))
        _ = coordinator.initialScrollTarget(currentPage: 3)

        coordinator.prepareForContent(currentPage: 2)

        XCTAssertTrue(coordinator.pageFrames.isEmpty)
        XCTAssertEqual(coordinator.viewportHeight, 1)
        XCTAssertEqual(coordinator.scrollTarget, 2)
        XCTAssertFalse(coordinator.layoutReady)
        XCTAssertFalse(coordinator.initialScrollCompleted)
        XCTAssertNil(coordinator.currentPageFromLayout(now: Date(timeIntervalSince1970: 11)))
    }

    func testRecordPageFramesReplacesStaleSnapshot() {
        let coordinator = ReaderVerticalCoordinator()

        coordinator.recordPageFrames([
            0: CGRect(x: 0, y: 0, width: 320, height: 480),
            1: CGRect(x: 0, y: 480, width: 320, height: 480)
        ])
        coordinator.recordPageFrames([
            3: CGRect(x: 0, y: 0, width: 320, height: 480)
        ])

        XCTAssertEqual(coordinator.pageFrames.keys.sorted(), [3])
    }

    func testInitialScrollTargetRequiresLayoutAndOnlyFiresOnce() {
        let coordinator = ReaderVerticalCoordinator()
        coordinator.prepareForContent(currentPage: 4)

        XCTAssertNil(coordinator.initialScrollTarget(currentPage: 4))

        coordinator.recordPageFrames([
            4: CGRect(x: 0, y: 0, width: 320, height: 480)
        ])

        XCTAssertEqual(coordinator.initialScrollTarget(currentPage: 4), 4)
        XCTAssertNil(coordinator.initialScrollTarget(currentPage: 4))
    }

    func testCurrentPageFromLayoutUsesViewportMidAfterScrollSettles() {
        let coordinator = ReaderVerticalCoordinator()
        coordinator.prepareForContent(currentPage: 0)
        coordinator.updateViewportHeight(400)
        coordinator.recordPageFrames([
            0: CGRect(x: 0, y: -360, width: 320, height: 300),
            1: CGRect(x: 0, y: -20, width: 320, height: 300),
            2: CGRect(x: 0, y: 320, width: 320, height: 300)
        ])

        XCTAssertEqual(
            coordinator.currentPageFromLayout(now: Date(timeIntervalSince1970: 20)),
            1
        )
    }

    func testCurrentPageFromLayoutWaitsForProgrammaticScrollToSettle() {
        let coordinator = ReaderVerticalCoordinator()
        coordinator.prepareForContent(currentPage: 0)
        coordinator.updateViewportHeight(400)
        coordinator.recordPageFrames([
            0: CGRect(x: 0, y: -360, width: 320, height: 300),
            1: CGRect(x: 0, y: -20, width: 320, height: 300),
            2: CGRect(x: 0, y: 320, width: 320, height: 300)
        ])
        _ = coordinator.scrollToPage(2, totalPages: 3, at: Date(timeIntervalSince1970: 100))

        XCTAssertNil(coordinator.currentPageFromLayout(now: Date(timeIntervalSince1970: 100.05)))
        XCTAssertEqual(coordinator.currentPageFromLayout(now: Date(timeIntervalSince1970: 100.3)), 1)
    }

    func testScrollToPageClampsTargetWithinBounds() {
        let coordinator = ReaderVerticalCoordinator()

        XCTAssertEqual(coordinator.scrollToPage(99, totalPages: 5, at: Date(timeIntervalSince1970: 10)), 4)
        XCTAssertEqual(coordinator.scrollTarget, 4)
        XCTAssertEqual(coordinator.scrollToPage(-3, totalPages: 5, at: Date(timeIntervalSince1970: 11)), 0)
        XCTAssertEqual(coordinator.scrollTarget, 0)
    }

    func testPendingSettledLayoutUpdateDelayReportsRemainingDelayAfterProgrammaticScroll() {
        let coordinator = ReaderVerticalCoordinator()
        coordinator.prepareForContent(currentPage: 0)
        coordinator.updateViewportHeight(400)
        coordinator.recordPageFrames([
            0: CGRect(x: 0, y: -360, width: 320, height: 300),
            1: CGRect(x: 0, y: -20, width: 320, height: 300),
            2: CGRect(x: 0, y: 320, width: 320, height: 300)
        ])
        _ = coordinator.scrollToPage(2, totalPages: 3, at: Date(timeIntervalSince1970: 100))

        let remainingDelay = coordinator.pendingSettledLayoutUpdateDelay(now: Date(timeIntervalSince1970: 100.05))

        XCTAssertNotNil(remainingDelay)
        XCTAssertEqual(remainingDelay ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertNil(coordinator.pendingSettledLayoutUpdateDelay(now: Date(timeIntervalSince1970: 100.3)))
    }
}
