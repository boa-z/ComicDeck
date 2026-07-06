import SwiftUI

struct CoverArtworkView: View {
    let urlString: String?
    var refererURLString: String? = nil
    var fileURL: URL? = nil
    let width: CGFloat
    let height: CGFloat
    var reloadToken: Int = 0

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
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .accessibilityHidden(true)
    }
}
