import SwiftUI

struct ComicDetailSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(AppSurface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppSurface.border)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 16, y: 8)
    }
}

struct ComicDetailHeroSection: View {
    let item: ComicSummary
    let detail: ComicDetail
    let sourceName: String
    let chapterCount: Int
    let commentCount: Int
    let browserURLString: String?
    let showContinue: Bool
    let isBookmarked: Bool
    let bookmarkWorking: Bool
    let queueingAll: Bool
    let queueAllProgressText: String
    let canShowComments: Bool
    let hasChapters: Bool
    let onTapChapters: () -> Void
    let onTapComments: () -> Void
    let onTapTags: (() -> Void)?
    let onContinue: () -> Void
    let onStart: () -> Void
    let onToggleBookmark: () -> Void
    let onOpenComments: () -> Void
    let onQueueAll: () -> Void
    let onDownloadSingle: () -> Void
    @Binding var showFullDescription: Bool
    @State private var collapsedHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    private var resolvedTitle: String {
        detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title : detail.title
    }

    private var descriptionText: String? {
        guard let text = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private var briefInfoItems: [BriefInfoItem] {
        var items: [BriefInfoItem] = [
            .init(value: "\(chapterCount)", caption: "Chapters", icon: "books.vertical", action: onTapChapters),
            .init(value: "\(commentCount)", caption: "Comments", icon: "text.bubble", action: onTapComments)
        ]
        if !item.tags.isEmpty, let onTapTags {
            items.append(.init(value: "\(item.tags.count)", caption: "Tags", icon: "tag", action: onTapTags))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(alignment: .top, spacing: AppSpacing.lg) {
                CoverArtworkView(
                    urlString: detail.cover ?? item.coverURL,
                    width: 112,
                    height: 156
                )
                .overlay(alignment: .bottomTrailing) {
                    if browserURLString != nil {
                        Image(systemName: "safari")
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(resolvedTitle)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Label(sourceName, systemImage: "shippingbox")
                        if let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                            Label(author, systemImage: "person")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            briefInfoGrid

            if let descriptionText {
                let needsExpansion = expandedHeight > collapsedHeight + 1

                VStack(alignment: .leading, spacing: 8) {
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(showFullDescription ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            Text(descriptionText)
                                .font(.subheadline)
                                .lineLimit(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .readHeight { collapsedHeight = $0 }
                        }
                        .background {
                            Text(descriptionText)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .readHeight { expandedHeight = $0 }
                        }

                    if needsExpansion {
                        Button(showFullDescription ? "Show Less" : "Show More") {
                            showFullDescription.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                    }
                }
            }

            heroActions

            if !item.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(item.tags.enumerated()), id: \.offset) { _, tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppSurface.elevated, in: Capsule())
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Summary tags")
                .accessibilityValue(item.tags.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppSurface.card, AppSurface.elevated.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(AppSurface.border)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 18, y: 12)
        .accessibilityElement(children: .contain)
    }

    private var briefInfoGrid: some View {
        HStack(spacing: 10) {
            ForEach(briefInfoItems) { item in
                briefInfoButton(item: item)
            }
        }
    }

    private var heroActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if showContinue {
                    actionButton(
                        title: "Continue",
                        icon: "play.fill",
                        prominence: .primary,
                        action: onContinue
                    )
                }

                actionButton(
                    title: "Start",
                    icon: "book.fill",
                    prominence: showContinue ? .secondary : .primary,
                    action: onStart
                )
            }

            HStack(spacing: 10) {
                actionButton(
                    title: isBookmarked ? "Bookmarked" : "Bookmark",
                    icon: isBookmarked ? "bookmark.fill" : "bookmark",
                    prominence: isBookmarked ? .tinted : .secondary,
                    disabled: bookmarkWorking,
                    action: onToggleBookmark
                )

                if canShowComments {
                    actionButton(
                        title: "Comments",
                        icon: "text.bubble",
                        prominence: .secondary,
                        action: onOpenComments
                    )
                }
            }

            HStack(spacing: 10) {
                actionButton(
                    title: hasChapters ? (queueingAll ? (queueAllProgressText.isEmpty ? "Queueing..." : queueAllProgressText) : "Queue All") : "Download",
                    icon: "arrow.down.circle",
                    prominence: .secondary,
                    disabled: queueingAll,
                    action: hasChapters ? onQueueAll : onDownloadSingle
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private func briefInfoButton(item: BriefInfoItem) -> some View {
        Button(action: item.action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: item.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTint.accent)
                    .frame(width: 24, height: 24)
                    .background(AppTint.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.value)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(item.caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 84, alignment: .topLeading)
            .padding(10)
            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.caption)
        .accessibilityValue(item.value)
        .accessibilityHint("Jump to \(item.caption.lowercased())")
    }

    private func actionButton(
        title: String,
        icon: String,
        prominence: ActionProminence,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(backgroundStyle(for: prominence), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .foregroundStyle(foregroundStyle(for: prominence))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    private func backgroundStyle(for prominence: ActionProminence) -> some ShapeStyle {
        switch prominence {
        case .primary:
            AppTint.accent
        case .secondary:
            AppSurface.elevated
        case .tinted:
            AppTint.success.opacity(0.16)
        }
    }

    private func foregroundStyle(for prominence: ActionProminence) -> Color {
        switch prominence {
        case .primary:
            .white
        case .secondary:
            .primary
        case .tinted:
            AppTint.success
        }
    }

    private struct BriefInfoItem: Identifiable {
        let id = UUID()
        let value: String
        let caption: String
        let icon: String
        let action: () -> Void
    }

    private enum ActionProminence {
        case primary
        case secondary
        case tinted
    }
}

struct ComicDetailTagsSection: View {
    let groups: [TagGroup]
    let onTagTap: (String, String) -> Void

    var body: some View {
        if !groups.isEmpty {
            ComicDetailSectionCard(title: "Tags", subtitle: "Use tags to jump across source taxonomy") {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                            FlexibleTagLayout(tags: group.values) { value in
                                Button(value) {
                                    onTagTap(group.title, value)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("\(group.title): \(value)")
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ComicDetailFavoriteSection: View {
    let effectiveIsFavorited: Bool
    let favoriteFolders: [FavoriteFolder]
    let isRootFavoriteWorking: Bool
    let favoriteStatus: String
    let onToggleFavorite: () -> Void
    let onToggleFolderFavorite: (FavoriteFolder) -> Void
    let isFolderFavoriteWorking: (String) -> Bool

    var body: some View {
        ComicDetailSectionCard(title: "Source Favorite", subtitle: "Sync the comic with source-side favorites") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack {
                    Label("Status", systemImage: effectiveIsFavorited ? "heart.fill" : "heart")
                        .foregroundStyle(effectiveIsFavorited ? AppTint.success : .secondary)
                    Spacer()
                    Text(effectiveIsFavorited ? "Favorited" : "Not Favorited")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(effectiveIsFavorited ? AppTint.success : .secondary)
                }

                if !favoriteFolders.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(favoriteFolders) { folder in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(folder.isFavorited ? "Already in folder" : "Not in folder")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(folder.isFavorited ? "Remove" : "Add") {
                                    onToggleFolderFavorite(folder)
                                }
                                .disabled(isFolderFavoriteWorking(folder.id))
                                .buttonStyle(.bordered)
                            }
                            .padding(AppSpacing.md)
                            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        }
                    }
                } else {
                    Button(action: onToggleFavorite) {
                        HStack {
                            if isRootFavoriteWorking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(effectiveIsFavorited ? "Remove Favorite" : "Add Favorite")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: effectiveIsFavorited ? "heart.slash" : "heart")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRootFavoriteWorking)
                }

                if !favoriteStatus.isEmpty {
                    Text(favoriteStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Favorite status")
                        .accessibilityValue(favoriteStatus)
                }
            }
        }
    }
}

struct ComicDetailCommentsSection: View {
    let title: String
    let canLoad: Bool
    let previewComments: [ComicComment]
    let isPreviewExpanded: Bool
    let previewNote: String?
    let onTogglePreview: () -> Void
    let onOpenComments: () -> Void

    var body: some View {
        ComicDetailSectionCard(title: title, subtitle: "Preview and inspect the source comment thread") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if canLoad {
                    Button(action: onOpenComments) {
                        Label("View All Comments", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if previewComments.isEmpty {
                    Text("No preview comments in detail payload.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button(isPreviewExpanded ? "Hide Preview" : "Show Preview") {
                        onTogglePreview()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))

                    if isPreviewExpanded {
                        VStack(spacing: 10) {
                            ForEach(previewComments) { comment in
                                CommentPreviewRow(comment: comment)
                                    .padding(AppSpacing.md)
                                    .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                            }
                        }
                    } else {
                        Text("Preview hidden. Tap “Show Preview” to inspect inline comments.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let previewNote {
                    Text(previewNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ComicDetailChaptersSection: View {
    let chapters: [ComicChapter]
    let chapterQuery: Binding<String>
    let chapterDescending: Binding<Bool>
    let continueChapterID: String?
    let downloadStateByChapterID: [String: DownloadStatus]
    let onReadSingleChapter: () -> Void
    let onDownloadSingleChapter: () -> Void
    let onReadChapter: (ComicChapter) -> Void
    let onDownloadChapter: (ComicChapter) -> Void

    var body: some View {
        ComicDetailSectionCard(
            title: "Chapters",
            subtitle: chapters.isEmpty ? "This source exposes a single chapter entry" : "\(chapters.count) chapters available"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if chapters.isEmpty {
                    Button("Read (single chapter)") {
                        onReadSingleChapter()
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onDownloadSingleChapter()
                    } label: {
                        Label("Download Chapter 1", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    HStack(spacing: AppSpacing.sm) {
                        TextField("Search chapter", text: chapterQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                        Button {
                            chapterDescending.wrappedValue.toggle()
                        } label: {
                            Image(systemName: chapterDescending.wrappedValue ? "arrow.down.to.line" : "arrow.up.to.line")
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(chapterDescending.wrappedValue ? "Sorted descending" : "Sorted ascending")
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(chapters) { chapter in
                            chapterRow(chapter)
                        }
                    }
                }
            }
        }
    }

    private func chapterRow(_ chapter: ComicChapter) -> some View {
        let title = chapter.title.isEmpty ? chapter.id : chapter.title
        let downloadStatus = downloadStateByChapterID[chapter.id]
        return HStack(alignment: .center, spacing: AppSpacing.md) {
            Button {
                onReadChapter(chapter)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        if continueChapterID == chapter.id {
                            badge("Continue", tint: .blue)
                        }
                        if let downloadStatus {
                            badge(downloadBadgeText(for: downloadStatus), tint: downloadBadgeTint(for: downloadStatus))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read \(title)")
            .accessibilityHint("Open this chapter in the reader")

            Button {
                if downloadStatus != .completed && downloadStatus != .downloading && downloadStatus != .pending {
                    onDownloadChapter(chapter)
                }
            } label: {
                Image(systemName: downloadButtonIcon(for: downloadStatus))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(downloadStatus == .completed || downloadStatus == .downloading || downloadStatus == .pending)
            .accessibilityLabel("Download \(title)")
        }
        .padding(AppSpacing.md)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private func downloadBadgeText(for status: DownloadStatus) -> String {
        switch status {
        case .completed: return "Offline"
        case .downloading: return "Downloading"
        case .pending: return "Queued"
        case .failed: return "Failed"
        }
    }

    private func downloadBadgeTint(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: return AppTint.success
        case .downloading: return AppTint.accent
        case .pending: return AppTint.warning
        case .failed: return AppTint.danger
        }
    }

    private func downloadButtonIcon(for status: DownloadStatus?) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .pending: return "clock.fill"
        case .failed: return "arrow.clockwise.circle"
        case nil: return "arrow.down.circle"
        }
    }
}

private struct FlexibleTagLayout<Content: View>: View {
    let tags: [String]
    let content: (String) -> Content

    var body: some View {
        FlowTagLayout(spacing: 8, rowSpacing: 8) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                content(tag)
            }
        }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func readHeight(onChange: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}

private struct FlowTagLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                totalHeight += currentRowHeight + rowSpacing
                maxRowWidth = max(maxRowWidth, currentX - spacing)
                currentX = 0
                currentRowHeight = 0
            }

            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }

        if !subviews.isEmpty {
            totalHeight += currentRowHeight
            maxRowWidth = max(maxRowWidth, max(0, currentX - spacing))
        }

        return CGSize(width: proposal.width ?? maxRowWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            subview.place(
                at: origin,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            origin.x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
