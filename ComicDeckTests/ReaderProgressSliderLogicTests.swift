import XCTest
@testable import ComicDeck

@MainActor
final class ReaderProgressSliderLogicTests: XCTestCase {
    func testSliderDisplayValueFollowsCurrentPageAfterDragEndsInLTR() {
        var state = ReaderProgressSliderState()
        let currentValue = ReaderProgressSliderMapper.displayValue(currentPage: 3, totalPages: 10, readerMode: .ltr)

        state.beginDragging(initialValue: currentValue)
        state.updateDragValue(7)
        state.endDragging()

        let nextValue = ReaderProgressSliderMapper.displayValue(currentPage: 8, totalPages: 10, readerMode: .ltr)
        XCTAssertEqual(state.displayValue(currentValue: nextValue), 8)
    }

    func testSliderDisplayValueFollowsCurrentPageAfterDragEndsInRTL() {
        var state = ReaderProgressSliderState()
        let currentValue = ReaderProgressSliderMapper.displayValue(currentPage: 6, totalPages: 10, readerMode: .rtl)

        state.beginDragging(initialValue: currentValue)
        state.updateDragValue(2)
        state.endDragging()

        let nextValue = ReaderProgressSliderMapper.displayValue(currentPage: 7, totalPages: 10, readerMode: .rtl)
        XCTAssertEqual(state.displayValue(currentValue: nextValue), 2)
    }

    func testSliderDisplayValueFollowsCurrentPageAfterDragEndsInVertical() {
        var state = ReaderProgressSliderState()
        let currentValue = ReaderProgressSliderMapper.displayValue(currentPage: 4, totalPages: 10, readerMode: .vertical)

        state.beginDragging(initialValue: currentValue)
        state.updateDragValue(8)
        state.endDragging()

        let nextValue = ReaderProgressSliderMapper.displayValue(currentPage: 9, totalPages: 10, readerMode: .vertical)
        XCTAssertEqual(state.displayValue(currentValue: nextValue), 9)
    }

    func testExternalPageChangeClearsStaleDragStateAndResyncsSlider() {
        var state = ReaderProgressSliderState()
        let initialValue = ReaderProgressSliderMapper.displayValue(currentPage: 3, totalPages: 10, readerMode: .ltr)

        state.beginDragging(initialValue: initialValue)
        state.updateDragValue(7)
        state.syncAfterExternalPageChange(currentValue: 8)

        XCTAssertEqual(state.displayValue(currentValue: 8), 8)
    }
}
