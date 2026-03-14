import SwiftUI
import UIKit

struct CoverArtworkView: View {
    let urlString: String?
    var fileURL: URL? = nil
    let width: CGFloat
    let height: CGFloat
    var reloadToken: Int = 0

    var body: some View {
        Group {
            if let fileURL,
               let image = UIImage(contentsOfFile: fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            } else {
                AsyncImage(url: URL(string: urlString ?? "")) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: width, height: height)
                            .background(AppSurface.subtle)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title3)
                            .frame(width: width, height: height)
                            .foregroundStyle(.secondary)
                            .background(AppSurface.subtle)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .id("\(fileURL?.absoluteString ?? urlString ?? "__empty__")#\(reloadToken)")
        .accessibilityHidden(true)
    }
}
