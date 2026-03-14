import Foundation
import Observation

@MainActor
@Observable
final class CategoryScreenModel {
    var profile: CategoryPageProfile = .empty
    var rankingProfile: CategoryRankingProfile = .empty
    var didInitialLoad = false
    var status = "Ready"

    func reload(using vm: ReaderViewModel) async {
        rankingProfile = .empty
        profile = .empty
        guard let source = vm.sourceManager.selectedSource else { return }
        do {
            profile = try await vm.loadCategoryPageProfile(sourceKey: source.key)
            rankingProfile = try await vm.loadCategoryRankingProfile(sourceKey: source.key)
            if profile.parts.isEmpty && !canShowRankingEntry {
                status = "This source does not provide category page"
            } else {
                status = "Category ready: \(profile.title)"
            }
        } catch {
            status = "Category init failed: \(error.localizedDescription)"
        }
    }

    var canShowRankingEntry: Bool {
        profile.enableRankingPage || !rankingProfile.options.isEmpty || rankingProfile.supportsLoadPage || rankingProfile.supportsLoadNext
    }
}
