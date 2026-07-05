import SwiftUI

struct ComicPreviewThumbnailImage: View {
    let urlString: String
    let refererURLString: String?
    let decodeSize: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?
    @State private var loadedIdentity = ""
    @State private var failed = false

    init(
        urlString: String,
        refererURLString: String? = nil,
        decodeSize: CGSize = CGSize(width: 180, height: 250)
    ) {
        self.urlString = urlString
        self.refererURLString = refererURLString
        self.decodeSize = decodeSize
    }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppSurface.subtle)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppSurface.subtle)
            }
        }
        .task(id: loadIdentity) {
            await load()
        }
    }

    private var loadIdentity: String {
        [
            urlString,
            refererURLString ?? "",
            "\(Int(displayScale.rounded(.up)))"
        ].joined(separator: "|")
    }

    private var request: URLRequest? {
        var headers: [String: String] = [:]
        if let referer = refererURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !referer.isEmpty {
            headers["Referer"] = referer
        }
        return buildURLRequest(from: ImageRequest(
            url: urlString,
            method: "GET",
            headers: headers,
            body: nil
        ))
    }

    private func load() async {
        let identity = loadIdentity
        guard loadedIdentity != identity || image == nil else { return }
        if loadedIdentity != identity {
            image = nil
        }
        guard let request else {
            failed = true
            return
        }

        failed = false

        for attempt in 0..<2 {
            do {
                let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: .visible)
                try Task.checkCancellation()
                var decoded = await ReaderDecodedImageStore.shared.imageAsync(
                    for: request,
                    data: data,
                    targetSize: decodeSize,
                    scale: displayScale,
                    allowOriginalSize: false
                )
                if decoded == nil {
                    decoded = PlatformImage(data: data)
                }
                guard let decoded else {
                    throw ReaderImagePipelineError.invalidResponse
                }
                try Task.checkCancellation()
                image = decoded
                loadedIdentity = identity
                failed = false
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempt == 0 else {
                    failed = true
                    return
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }
}
