import Foundation

enum ReaderPrefetchPlanner {
    static func preferredPrefetchIndexes(current: Int, total: Int, distance: Int, direction: Int) -> [Int] {
        guard total > 0, distance > 0 else { return [] }

        var indexes: [Int] = []
        let forwardFirst = direction >= 0

        for step in 1...distance {
            let forward = current + step
            let backward = current - step

            if forwardFirst {
                if forward < total { indexes.append(forward) }
                if backward >= 0 { indexes.append(backward) }
            } else {
                if backward >= 0 { indexes.append(backward) }
                if forward < total { indexes.append(forward) }
            }
        }

        return indexes
    }
}
