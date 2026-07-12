import SwiftUI

struct ComicBrowseModePicker: View {
    @Binding var mode: ComicBrowseDisplayMode

    var body: some View {
        Menu {
            Picker(AppLocalization.text("browse.mode", "Browse Mode"), selection: $mode) {
                ForEach(ComicBrowseDisplayMode.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
        } label: {
            Image(systemName: mode.systemImage)
                .appMinTouchTarget()
        }
        .accessibilityLabel(AppLocalization.text("settings.appearance.browse_layout", "Comic Browse Layout"))
        .accessibilityValue(mode.title)
    }
}

struct SearchResultCard: View {
    let item: ComicSummary
    private let tagSummary: String?

    init(item: ComicSummary) {
        self.item = item
        self.tagSummary = comicTagSummary(from: item.tags, limit: 3, trimsEmptyValues: false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            CoverArtworkView(
                urlString: item.coverURL,
                refererURLString: item.id,
                size: AppCoverSize.list
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(item.title)
                    .font(AppTypography.cardTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(AppTypography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.sourceKey)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let tagSummary {
                    Text(tagSummary)
                        .font(AppTypography.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .appCardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(comicAccessibilityLabel(
            title: item.title,
            author: item.author,
            sourceKey: item.sourceKey,
            tags: tagSummary
        ))
    }
}

struct SearchResultGridCard: View {
    let item: ComicSummary
    private let tagSummary: String?

    init(item: ComicSummary) {
        self.item = item
        self.tagSummary = comicTagSummary(from: item.tags, limit: 2, trimsEmptyValues: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CoverArtworkView(
                urlString: item.coverURL,
                refererURLString: item.id,
                size: AppCoverSize.grid
            )
            .frame(maxWidth: .infinity)

            Text(item.title)
                .font(AppTypography.cardTitle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44, alignment: .topLeading)

            if let author = item.author, !author.isEmpty {
                Text(author)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(item.sourceKey)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let tagSummary {
                Text(tagSummary)
                    .font(AppTypography.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(comicAccessibilityLabel(
            title: item.title,
            author: item.author,
            sourceKey: item.sourceKey,
            tags: tagSummary
        ))
    }
}

struct ComicPreviewCard: View {
    let title: String
    let coverURL: String?
    let sourceKey: String
    let entityID: String
    let author: String?
    let tags: [String]
    let subtitle: String?
    var coverReloadToken: Int = 0
    private let tagSummary: String?

    init(
        title: String,
        coverURL: String?,
        sourceKey: String,
        entityID: String,
        author: String?,
        tags: [String],
        subtitle: String?,
        coverReloadToken: Int = 0
    ) {
        self.title = title
        self.coverURL = coverURL
        self.sourceKey = sourceKey
        self.entityID = entityID
        self.author = author
        self.tags = tags
        self.subtitle = subtitle
        self.coverReloadToken = coverReloadToken
        self.tagSummary = comicTagSummary(from: tags, limit: 3, trimsEmptyValues: true)
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            CoverArtworkView(
                urlString: coverURL,
                refererURLString: entityID,
                size: AppCoverSize.listCompact,
                reloadToken: coverReloadToken
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.cardTitle)
                    .lineLimit(2)

                Text("\(sourceKey) · \(entityID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let author, !author.isEmpty {
                    Text(AppLocalization.format("comic.author_format", "Author: %@", author))
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let tagSummary {
                    Text(tagSummary)
                        .font(AppTypography.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .appCardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(comicAccessibilityLabel(
            title: title,
            author: author,
            sourceKey: sourceKey,
            tags: tagSummary,
            subtitle: subtitle
        ))
    }
}

struct ComicPreviewGridCard: View {
    let title: String
    let coverURL: String?
    let sourceKey: String
    let entityID: String
    let author: String?
    let tags: [String]
    let subtitle: String?
    var coverReloadToken: Int = 0
    private let tagSummary: String?

    init(
        title: String,
        coverURL: String?,
        sourceKey: String,
        entityID: String,
        author: String?,
        tags: [String],
        subtitle: String?,
        coverReloadToken: Int = 0
    ) {
        self.title = title
        self.coverURL = coverURL
        self.sourceKey = sourceKey
        self.entityID = entityID
        self.author = author
        self.tags = tags
        self.subtitle = subtitle
        self.coverReloadToken = coverReloadToken
        self.tagSummary = comicTagSummary(from: tags, limit: 2, trimsEmptyValues: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CoverArtworkView(
                urlString: coverURL,
                refererURLString: entityID,
                size: AppCoverSize.grid,
                reloadToken: coverReloadToken
            )
            .frame(maxWidth: .infinity)

            Text(title)
                .font(AppTypography.cardTitle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44, alignment: .topLeading)

            Text(sourceKey)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let author, !author.isEmpty {
                Text(author)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let tagSummary {
                Text(tagSummary)
                    .font(AppTypography.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(entityID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(comicAccessibilityLabel(
            title: title,
            author: author,
            sourceKey: sourceKey,
            tags: tagSummary,
            subtitle: subtitle
        ))
    }
}

private func comicTagSummary(from tags: [String], limit: Int, trimsEmptyValues: Bool) -> String? {
    guard limit > 0, !tags.isEmpty else { return nil }

    var visibleTags: [String] = []
    visibleTags.reserveCapacity(min(limit, tags.count))
    for tag in tags {
        let value = trimsEmptyValues ? tag.trimmingCharacters(in: .whitespacesAndNewlines) : tag
        guard !trimsEmptyValues || !value.isEmpty else { continue }
        visibleTags.append(value)
        if visibleTags.count == limit { break }
    }

    guard !visibleTags.isEmpty else { return nil }
    return visibleTags.joined(separator: " · ")
}

private func comicAccessibilityLabel(
    title: String,
    author: String?,
    sourceKey: String,
    tags: String?,
    subtitle: String? = nil
) -> String {
    var parts = [title]
    if let author, !author.isEmpty {
        parts.append(author)
    }
    parts.append(sourceKey)
    if let tags, !tags.isEmpty {
        parts.append(tags)
    }
    if let subtitle, !subtitle.isEmpty {
        parts.append(subtitle)
    }
    return parts.joined(separator: ", ")
}
