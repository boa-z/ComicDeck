import SwiftUI

/// Shared comment preview row used by both iOS (`ComicDetailView`,
/// `ComicDetailSections`) and macOS (`MacComicDetailWorkspaceView`).
///
/// Extracted from `ComicDetailView.swift` so the iOS-only detail file can be
/// fully isolated behind a file-level `#if os(iOS)` without breaking the macOS
/// workspace, which still needs this row.
@MainActor
struct CommentPreviewRow: View {
    let comment: ComicComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.userName)
                    .font(.subheadline.weight(.semibold))
                if let time = comment.timeText, !time.isEmpty {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let score = comment.score {
                    Text("♥ \(score)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let replyCount = comment.replyCount, replyCount > 0 {
                    Text("↩ \(replyCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            RichTextContent(text: comment.content)
                .font(.subheadline)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
