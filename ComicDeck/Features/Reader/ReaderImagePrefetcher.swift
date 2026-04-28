import Foundation

@MainActor
final class ReaderImagePrefetcher {
    static let shared = ReaderImagePrefetcher()

    private var prefetchTask: Task<Void, Never>?

    private init() {}

    func preload(requests: [URLRequest], generation: Int) {
        guard !requests.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task(priority: .utility) {
            await ReaderImagePipeline.shared.prefetch(requests: requests, generation: generation)
        }
    }

    func cancel() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }
}
