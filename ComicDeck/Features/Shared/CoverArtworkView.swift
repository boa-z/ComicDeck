import SwiftUI

struct CoverArtworkView: View {
    let urlString: String?
    var refererURLString: String? = nil
    var fileURL: URL? = nil
    let width: CGFloat
    let height: CGFloat
    var reloadToken: Int = 0
    var cornerRadius: CGFloat = AppRadius.sm

    init(
        urlString: String?,
        refererURLString: String? = nil,
        fileURL: URL? = nil,
        width: CGFloat,
        height: CGFloat,
        reloadToken: Int = 0,
        cornerRadius: CGFloat = AppRadius.sm
    ) {
        self.urlString = urlString
        self.refererURLString = refererURLString
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.reloadToken = reloadToken
        self.cornerRadius = cornerRadius
    }

    init(
        urlString: String?,
        refererURLString: String? = nil,
        fileURL: URL? = nil,
        size: CGSize,
        reloadToken: Int = 0,
        cornerRadius: CGFloat = AppRadius.sm
    ) {
        self.init(
            urlString: urlString,
            refererURLString: refererURLString,
            fileURL: fileURL,
            width: size.width,
            height: size.height,
            reloadToken: reloadToken,
            cornerRadius: cornerRadius
        )
    }

    var body: some View {
        CachedRemoteImage(
            urlString: fileURL?.absoluteString ?? urlString,
            refererURLString: refererURLString,
            decodeSize: CGSize(width: width, height: height),
            contentMode: .fill,
            reloadToken: reloadToken,
            priority: .thumbnail
        )
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppSurface.border.opacity(0.9))
        )
        .shadow(color: Color.black.opacity(0.06), radius: 6, y: 3)
        .accessibilityHidden(true)
    }
}
