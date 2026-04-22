import Foundation
import SwiftUI

struct ReaderProgressSliderState {
    private(set) var isDragging = false
    private(set) var dragValue: Double = 0

    mutating func beginDragging(initialValue: Double) {
        isDragging = true
        dragValue = initialValue
    }

    mutating func updateDragValue(_ value: Double) {
        dragValue = value
    }

    mutating func endDragging() {
        isDragging = false
    }

    mutating func syncAfterExternalPageChange(currentValue: Double) {
        if isDragging, dragValue != currentValue {
            isDragging = false
        }
        if !isDragging {
            dragValue = currentValue
        }
    }

    func displayValue(currentValue: Double) -> Double {
        isDragging ? dragValue : currentValue
    }
}

enum ReaderProgressSliderMapper {
    static func displayValue(currentPage: Int, totalPages: Int, readerMode: ReaderMode) -> Double {
        guard totalPages > 0 else { return 0 }
        if readerMode == .rtl {
            return Double(max(totalPages - 1 - currentPage, 0))
        }
        return Double(max(currentPage, 0))
    }

    static func currentPage(for sliderValue: Double, totalPages: Int, readerMode: ReaderMode) -> Int {
        let upperBound = max(totalPages - 1, 0)
        let clamped = max(0, min(upperBound, Int(sliderValue.rounded())))
        if readerMode == .rtl {
            return upperBound - clamped
        }
        return clamped
    }
}
