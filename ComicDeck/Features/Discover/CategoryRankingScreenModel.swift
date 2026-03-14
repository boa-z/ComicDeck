import Foundation
import Observation

@MainActor
@Observable
final class CategoryRankingScreenModel {
    let sourceKey: String
    let initialProfile: CategoryRankingProfile

    var profile: CategoryRankingProfile = .empty
    var selectedOption = ""
    var isLoading = false
    var didInitialLoad = false
    var results: [ComicSummary] = []
    var page = 1
    var hasMore = false
    var nextToken: String?
    var status = "Ready"

    init(sourceKey: String, initialProfile: CategoryRankingProfile) {
        self.sourceKey = sourceKey
        self.initialProfile = initialProfile
    }

    func prepareAndLoadInitial(using vm: ReaderViewModel) async {
        if initialProfile.options.isEmpty {
            do {
                profile = try await vm.loadCategoryRankingProfile(sourceKey: sourceKey)
            } catch {
                profile = .empty
            }
        } else {
            profile = initialProfile
        }
        selectedOption = profile.options.first?.value ?? ""
        guard !selectedOption.isEmpty else {
            status = "Ranking options are not available for current source"
            return
        }
        await loadRanking(using: vm, page: 1, append: false)
    }

    func loadRanking(using vm: ReaderViewModel, page: Int, append: Bool) async {
        guard !isLoading else { return }
        guard !selectedOption.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await vm.loadCategoryRanking(
                sourceKey: sourceKey,
                option: selectedOption,
                page: max(1, page),
                nextToken: append ? nextToken : nil
            )
            if append {
                results.append(contentsOf: loaded.comics)
            } else {
                results = loaded.comics
            }
            self.page = max(1, page)
            nextToken = loaded.nextToken
            if profile.supportsLoadPage, let maxPage = loaded.maxPage {
                hasMore = self.page < maxPage
            } else if profile.supportsLoadNext {
                hasMore = loaded.nextToken != nil
            } else if let maxPage = loaded.maxPage {
                hasMore = self.page < maxPage
            } else {
                hasMore = !loaded.comics.isEmpty
            }
            status = "Loaded \(loaded.comics.count) items (page \(self.page))"
        } catch {
            status = "Ranking load failed: \(error.localizedDescription)"
        }
    }
}
