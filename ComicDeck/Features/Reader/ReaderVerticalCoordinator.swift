import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ReaderVerticalCoordinator {
    private enum Constants {
        static let settledScrollDelay: TimeInterval = 0.15
    }

    var pageFrames: [Int: CGRect] = [:]
    var viewportHeight: CGFloat = 1
    var scrollTarget: Int?
    var layoutReady = false
    var initialScrollCompleted = false

    private var lastProgrammaticScrollAt: Date = .distantPast

    func prepareForContent(currentPage: Int) {
        pageFrames = [:]
        viewportHeight = 1
        scrollTarget = currentPage
        layoutReady = false
        initialScrollCompleted = false
        lastProgrammaticScrollAt = .distantPast
    }

    func updateViewportHeight(_ height: CGFloat) {
        viewportHeight = max(1, height)
    }

    func recordPageFrames(_ frames: [Int: CGRect]) {
        pageFrames = frames
        layoutReady = !frames.isEmpty
    }

    func initialScrollTarget(currentPage: Int) -> Int? {
        guard layoutReady, !initialScrollCompleted else { return nil }
        initialScrollCompleted = true
        scrollTarget = currentPage
        return currentPage
    }

    @discardableResult
    func scrollToPage(_ target: Int, totalPages: Int, at now: Date = Date()) -> Int {
        let clamped = max(0, min(max(totalPages - 1, 0), target))
        scrollTarget = clamped
        lastProgrammaticScrollAt = now
        return clamped
    }

    func currentPageFromLayout(now: Date = Date()) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        guard now.timeIntervalSince(lastProgrammaticScrollAt) > Constants.settledScrollDelay else {
            return nil
        }

        let viewportMid = viewportHeight * 0.5
        return pageFrames.min { lhs, rhs in
            abs(lhs.value.midY - viewportMid) < abs(rhs.value.midY - viewportMid)
        }?.key
    }

    func clearTrackedFrames() {
        pageFrames.removeAll(keepingCapacity: false)
        layoutReady = false
    }
}
