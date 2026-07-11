import SwiftUI

struct ComicDetailPreviewSection: View {
    let images: [ComicPreviewImage]
    let loading: Bool
    let canLoadMore: Bool
    let errorText: String
    let onOpenPage: (ComicPreviewImage) -> Void
    let onLoadMore: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 136), spacing: AppSpacing.sm)
    ]

    var body: some View {
        if !images.isEmpty || loading || canLoadMore || !errorText.isEmpty {
            ComicDetailSectionCard(
                title: AppLocalization.text("detail.preview.title", "Preview"),
                subtitle: AppLocalization.text("detail.preview.subtitle", "Tap a page preview to continue reading from that page")
            ) {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    if images.isEmpty, loading {
                        ProgressView(AppLocalization.text("detail.preview.loading", "Loading previews..."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !images.isEmpty {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.sm) {
                            ForEach(images) { image in
                                ComicDetailPreviewTile(image: image) {
                                    onOpenPage(image)
                                }
                                .onAppear {
                                    if image.id == images.last?.id, canLoadMore {
                                        onLoadMore()
                                    }
                                }
                            }
                        }
                    }

                    if loading, !images.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm)
                    } else if canLoadMore, errorText.isEmpty {
                        Button(AppLocalization.text("common.load_more", "Load More"), systemImage: "arrow.down.circle", action: onLoadMore)
                            .buttonStyle(.bordered)
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(AppTint.danger)
                        Button(AppLocalization.text("common.retry", "Retry"), systemImage: "arrow.clockwise", action: onLoadMore)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

private struct ComicDetailPreviewTile: View {
    let image: ComicPreviewImage
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    urlString: image.imageURL,
                    imageRequest: image.imageRequest,
                    refererURLString: image.sourceURL,
                    decodeSize: CGSize(width: 180, height: 250),
                    contentMode: .fill,
                    priority: .thumbnail
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .clipped()

                Text(String(image.page))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(AppSurface.border)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.format(
            "detail.preview.open_page_accessibility_format",
            "Open page %lld",
            Int64(image.page)
        ))
    }
}
