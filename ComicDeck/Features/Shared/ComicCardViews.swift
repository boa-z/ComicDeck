import SwiftUI

struct ComicBrowseModePicker: View {
    @Binding var mode: ComicBrowseDisplayMode

    var body: some View {
        Menu {
            Picker("Browse Mode", selection: $mode) {
                ForEach(ComicBrowseDisplayMode.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
        } label: {
            Image(systemName: mode.systemImage)
        }
        .accessibilityLabel("Browse layout")
        .accessibilityValue(mode.title)
    }
}

struct SearchResultCard: View {
    let item: ComicSummary

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            CoverArtworkView(urlString: item.coverURL, width: 68, height: 96)

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

                if !item.tags.isEmpty {
                    Text(item.tags.prefix(3).joined(separator: " · "))
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CoverArtworkView(urlString: item.coverURL, width: 140, height: 196)
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

            if !item.tags.isEmpty {
                Text(item.tags.prefix(2).joined(separator: " · "))
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

    private var normalizedTags: [String] {
        tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            CoverArtworkView(urlString: coverURL, width: 56, height: 80, reloadToken: coverReloadToken)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text("\(sourceKey) · \(entityID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let author, !author.isEmpty {
                    Text("Author: \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !normalizedTags.isEmpty {
                    Text(normalizedTags.prefix(3).joined(separator: " · "))
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

    private var normalizedTags: [String] {
        tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CoverArtworkView(urlString: coverURL, width: 140, height: 196, reloadToken: coverReloadToken)
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
            } else if !normalizedTags.isEmpty {
                Text(normalizedTags.prefix(2).joined(separator: " · "))
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
