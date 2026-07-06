import SwiftUI

@MainActor
struct CachedRemoteImage: View {
    let urlString: String?
    let imageRequest: ImageRequest?
    let refererURLString: String?
    let decodeSize: CGSize
    let contentMode: ContentMode
    let reloadToken: Int
    let failureSystemImage: String
    let priority: ReaderImagePipeline.LoadPriority

    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?
    @State private var loadedIdentity = ""
    @State private var activeResourceIdentity = ""
    @State private var failed = false
    @State private var retryToken = 0
    @State private var automaticRetryCount = 0
    @State private var preferredRequestKey: String?

    init(
        urlString: String?,
        imageRequest: ImageRequest? = nil,
        refererURLString: String? = nil,
        decodeSize: CGSize,
        contentMode: ContentMode = .fill,
        reloadToken: Int = 0,
        failureSystemImage: String = "photo",
        priority: ReaderImagePipeline.LoadPriority = .visible
    ) {
        self.urlString = urlString
        self.imageRequest = imageRequest
        self.refererURLString = refererURLString
        self.decodeSize = decodeSize
        self.contentMode = contentMode
        self.reloadToken = reloadToken
        self.failureSystemImage = failureSystemImage
        self.priority = priority
    }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: failureSystemImage)
                    .font(.title3)
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
        .onAppear(perform: retryIfNeeded)
    }

    private var resourceIdentity: String {
        [
            urlString ?? "",
            imageRequest.map(imageRequestKey) ?? "",
            normalizedRefererURLString ?? "",
            cropRegion?.cacheKey ?? "",
            "\(Int(max(decodeSize.width, 1).rounded(.up)))x\(Int(max(decodeSize.height, 1).rounded(.up)))",
            "\(Int(displayScale.rounded(.up)))",
            "\(reloadToken)",
            "\(priority.rawValue)"
        ].joined(separator: "|")
    }

    private var loadIdentity: String {
        [
            resourceIdentity,
            "\(retryToken)"
        ].joined(separator: "|")
    }

    private var requestCandidates: [URLRequest] {
        guard urlString != nil || imageRequest != nil else { return [] }
        var seen = Set<String>()
        var requests: [URLRequest] = []
        if let imageRequest,
           let request = buildURLRequest(from: imageRequest),
           seen.insert(urlRequestKey(request)).inserted {
            requests.append(request)
        }
        for referer in refererCandidates {
            guard let request = makeRequest(referer: referer) else { continue }
            guard seen.insert(urlRequestKey(request)).inserted else { continue }
            requests.append(request)
        }
        guard let preferredRequestKey,
              let preferredIndex = requests.firstIndex(where: { urlRequestKey($0) == preferredRequestKey })
        else {
            return requests
        }
        let preferred = requests.remove(at: preferredIndex)
        requests.insert(preferred, at: 0)
        return requests
    }

    private var refererCandidates: [String?] {
        var candidates: [String?] = []
        if let referer = normalizedRefererURLString {
            candidates.append(referer)
        }
        if let imageOrigin = imageOriginRefererURLString {
            candidates.append(imageOrigin)
        }
        candidates.append(nil)
        return candidates
    }

    private func makeRequest(referer: String?) -> URLRequest? {
        guard let urlString = requestURLString else { return nil }
        var headers: [String: String] = [:]
        if let referer {
            headers["Referer"] = referer
        }
        return buildURLRequest(from: ImageRequest(
            url: urlString,
            method: "GET",
            headers: headers,
            body: nil
        ))
    }

    private var normalizedRefererURLString: String? {
        guard let referer = refererURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !referer.isEmpty else {
            return nil
        }
        let lowercased = referer.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            return nil
        }
        return referer
    }

    private var imageOriginRefererURLString: String? {
        guard let urlString = requestURLString else { return nil }
        guard let request = buildURLRequest(from: ImageRequest(
            url: urlString,
            method: "GET",
            headers: [:],
            body: nil
        )),
            let url = request.url,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host
        else {
            return nil
        }
        return "\(scheme)://\(host)/"
    }

    private var requestURLString: String? {
        guard let value = urlString ?? imageRequest?.url else { return nil }
        return ImageCropRegion.stripMarker(from: value)
    }

    private var cropRegion: ImageCropRegion? {
        ImageCropRegion.parse(from: urlString) ?? ImageCropRegion.parse(from: imageRequest?.url)
    }

    private func load() async {
        let identity = loadIdentity
        let currentResourceIdentity = resourceIdentity
        if loadedIdentity == identity, image != nil {
            return
        }
        if activeResourceIdentity != currentResourceIdentity {
            activeResourceIdentity = currentResourceIdentity
            automaticRetryCount = 0
            preferredRequestKey = nil
            image = nil
            failed = false
        } else if loadedIdentity != identity, image == nil {
            failed = false
        }
        let requests = requestCandidates
        guard !requests.isEmpty else {
            loadedIdentity = identity
            failed = true
            return
        }

        for attempt in 0..<4 {
            var lastError: Error?
            for request in requests {
                do {
                    let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: priority)
                    try Task.checkCancellation()
                    if reloadToken != 0 {
                        ReaderDecodedImageStore.shared.removeImage(
                            for: request,
                            targetSize: decodeSize,
                            scale: displayScale,
                            allowOriginalSize: false,
                            cropRegion: cropRegion
                        )
                    }
                    var decoded = await ReaderDecodedImageStore.shared.imageAsync(
                        for: request,
                        data: data,
                        targetSize: decodeSize,
                        scale: displayScale,
                        allowOriginalSize: false,
                        cropRegion: cropRegion
                    )
                    if decoded == nil {
                        decoded = PlatformImage(data: data)
                    }
                    guard let decoded else {
                        ReaderDecodedImageStore.shared.removeImage(
                            for: request,
                            targetSize: decodeSize,
                            scale: displayScale,
                            allowOriginalSize: false,
                            cropRegion: cropRegion
                        )
                        await ReaderImagePipeline.shared.removeCachedData(for: request)
                        throw ReaderImagePipelineError.invalidResponse
                    }
                    try Task.checkCancellation()
                    guard resourceIdentity == currentResourceIdentity else {
                        return
                    }
                    preferredRequestKey = urlRequestKey(request)
                    image = decoded
                    loadedIdentity = identity
                    failed = false
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    lastError = error
                    await ReaderImagePipeline.shared.removeCachedData(for: request)
                    ReaderDecodedImageStore.shared.removeImage(
                        for: request,
                        targetSize: decodeSize,
                        scale: displayScale,
                        allowOriginalSize: false,
                        cropRegion: cropRegion
                    )
                    continue
                }
            }

            guard attempt < 3 else {
                _ = lastError
                guard resourceIdentity == currentResourceIdentity else {
                    return
                }
                loadedIdentity = identity
                failed = true
                await scheduleAutomaticRetry(forResourceIdentity: currentResourceIdentity)
                return
            }
            try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
        }
    }

    private func scheduleAutomaticRetry(forResourceIdentity identity: String) async {
        guard automaticRetryCount < 2 else { return }
        let delay: Duration = automaticRetryCount == 0 ? .seconds(1) : .seconds(3)
        automaticRetryCount += 1
        do {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
        } catch {
            return
        }
        guard resourceIdentity == identity, failed, image == nil else {
            return
        }
        retryToken += 1
    }

    private func retryIfNeeded() {
        guard failed else { return }
        retryToken += 1
    }
}
