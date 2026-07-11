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
            CoverArtworkView(urlString: item.coverURL, refererURLString: item.id, width: 68, height: 96)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.sourceKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let tagSummary {
                    Text(tagSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .appCardStyle()
        .accessibilityElement(children: .combine)
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
            CoverArtworkView(urlString: item.coverURL, refererURLString: item.id, width: 140, height: 196)
                .frame(maxWidth: .infinity)

            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            if let author = item.author, !author.isEmpty {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(item.sourceKey)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let tagSummary {
                Text(tagSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
        .accessibilityElement(children: .combine)
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
                width: 56,
                height: 80,
                reloadToken: coverReloadToken
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text("\(sourceKey) · \(entityID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let author, !author.isEmpty {
                    Text(AppLocalization.format("comic.author_format", "Author: %@", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let tagSummary {
                    Text(tagSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .appCardStyle()
        .accessibilityElement(children: .combine)
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
                width: 140,
                height: 196,
                reloadToken: coverReloadToken
            )
                .frame(maxWidth: .infinity)

            Text(title)
                .font(.headline)
                .lineLimit(2)

            Text(sourceKey)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let author, !author.isEmpty {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let tagSummary {
                Text(tagSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(entityID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
        .accessibilityElement(children: .combine)
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
