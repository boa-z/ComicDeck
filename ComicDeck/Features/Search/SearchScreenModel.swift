import Foundation
import Observation

@MainActor
@Observable
final class SearchScreenModel {
    enum SearchTrigger: Equatable {
        case keyword
        case tag(String)
    }

    private enum PersistKey {
        static let recentKeywords = "search.recentKeywords"
    }

    var keyword = ""
    var results: [ComicSummary] = []
    var searchCurrentPage = 1
    var searchHasMore = false
    var searchNextToken: String?
    var status = "Ready"
    var isSearching = false
    var recentKeywords: [String] = []
    var lastSearchTrigger: SearchTrigger = .keyword

    init() {
        recentKeywords = Self.loadRecentKeywords()
    }

    func performSearch(
        using vm: ReaderViewModel,
        sourceKey: String?,
        options: [String],
        profile: SearchFeatureProfile,
        append: Bool,
        trigger: SearchTrigger = .keyword
    ) async {
        guard !isSearching else { return }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if !append {
                results = []
                status = "Type a keyword to start"
            }
            return
        }
        guard let sourceKey, !sourceKey.isEmpty else {
            status = "Please install and select a source first"
            return
        }

        isSearching = true
        defer { isSearching = false }

        let targetPage = append ? (searchCurrentPage + 1) : 1
        let nextToken = append && profile.supportsLoadNext ? searchNextToken : nil

        do {
            let response = try await vm.executeSearch(
                sourceKey: sourceKey,
                keyword: trimmed,
                options: options,
                page: targetPage,
                nextToken: nextToken
            )
            if append {
                results.append(contentsOf: response.pageResult.comics)
            } else {
                results = response.pageResult.comics
                lastSearchTrigger = trigger
            }
            searchCurrentPage = targetPage
            searchNextToken = response.pageResult.nextToken
            if profile.supportsLoadNext {
                searchHasMore = response.pageResult.nextToken != nil
            } else if let maxPage = response.pageResult.maxPage {
                searchHasMore = searchCurrentPage < maxPage
            } else {
                searchHasMore = !response.pageResult.comics.isEmpty
            }
            status = "\(response.sourceName): loaded \(response.pageResult.comics.count) items (page \(searchCurrentPage))"

            if !append {
                recordRecentKeyword(trimmed)
            }
        } catch {
            status = "Search failed: \(error.localizedDescription)"
            if !append {
                results = []
                searchHasMore = false
                searchCurrentPage = 1
                searchNextToken = nil
            }
        }
    }

    func searchByTag(
        _ tag: String,
        sourceKey: String,
        using vm: ReaderViewModel,
        options: [String],
        profile: SearchFeatureProfile
    ) async {
        let text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        keyword = text
        await performSearch(
            using: vm,
            sourceKey: sourceKey,
            options: options,
            profile: profile,
            append: false,
            trigger: .tag(text)
        )
    }

    func recordRecentKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentKeywords.removeAll { $0 == trimmed }
        recentKeywords.insert(trimmed, at: 0)
        if recentKeywords.count > 12 {
            recentKeywords = Array(recentKeywords.prefix(12))
        }
        persistRecentKeywords()
    }

    func clearRecentKeywords() {
        recentKeywords = []
        UserDefaults.standard.removeObject(forKey: PersistKey.recentKeywords)
    }

    private func persistRecentKeywords() {
        UserDefaults.standard.set(recentKeywords, forKey: PersistKey.recentKeywords)
    }

    private static func loadRecentKeywords() -> [String] {
        (UserDefaults.standard.array(forKey: PersistKey.recentKeywords) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
