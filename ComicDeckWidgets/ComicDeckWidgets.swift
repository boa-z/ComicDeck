import ActivityKit
import WidgetKit
import SwiftUI

struct ComicDownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var comicTitle: String
        var chapterTitle: String
        var status: String
        var downloadedPages: Int
        var totalPages: Int
        var updatedAt: Date
    }

    var chapterKey: String
}

struct ComicDownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ComicDownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.comicTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.chapterTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: progressValue(from: context.state))
                HStack(spacing: 8) {
                    Text(context.state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(context.state.downloadedPages)/\(max(context.state.totalPages, context.state.downloadedPages))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.downloadedPages)/\(max(context.state.totalPages, context.state.downloadedPages))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.comicTitle)
                            .font(.caption)
                            .lineLimit(1)
                        Text(context.state.chapterTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progressValue(from: context.state))
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle")
            } compactTrailing: {
                Text("\(compactProgressPercent(from: context.state))%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle")
            }
        }
    }

    private func progressValue(from state: ComicDownloadActivityAttributes.ContentState) -> Double {
        guard state.totalPages > 0 else { return 0 }
        let value = Double(state.downloadedPages) / Double(state.totalPages)
        return min(max(value, 0), 1)
    }

    private func compactProgressPercent(from state: ComicDownloadActivityAttributes.ContentState) -> Int {
        Int((progressValue(from: state) * 100).rounded())
    }
}

private struct ComicDeckPlaceholderEntry: TimelineEntry {
    let date: Date
}

private struct ComicDeckPlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComicDeckPlaceholderEntry {
        ComicDeckPlaceholderEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ComicDeckPlaceholderEntry) -> Void) {
        completion(ComicDeckPlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComicDeckPlaceholderEntry>) -> Void) {
        let entry = ComicDeckPlaceholderEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }
}

struct ComicDeckPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ComicDeckPlaceholderWidget", provider: ComicDeckPlaceholderProvider()) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("ComicDeck")
                    .font(.headline)
                Text("Open app to download comics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("ComicDeck")
        .description("Quick access widget for ComicDeck.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ComicDeckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ComicDeckPlaceholderWidget()
        ComicDownloadLiveActivityWidget()
    }
}
