import SwiftUI

struct ReaderOverlayView: View {
    let chapterTitle: String
    let chapterID: String
    let comicTitle: String
    let offlineStatusText: String
    let displayedPageIndex: Int
    let totalPages: Int
    let readerMode: ReaderMode
    let animatePageTransitions: Bool
    @Binding var currentPage: Int
    let previousChapterTitle: String?
    let nextChapterTitle: String?
    let onDismiss: () -> Void
    let onOpenModeMenu: ((ReaderMode) -> Void)?
    let onOpenSettings: () -> Void
    let onReload: () -> Void
    let onOpenPreviousChapter: () -> Void
    let onOpenNextChapter: () -> Void
    let onJumpToVerticalPage: (Int) -> Void

    private var safePageUpperBound: Int {
        max(totalPages - 1, 0)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                guard totalPages > 0 else { return 0 }
                if readerMode == .rtl {
                    return Double(max(totalPages - 1 - currentPage, 0))
                }
                return Double(max(currentPage, 0))
            },
            set: { newValue in
                guard totalPages > 0 else { return }
                let clamped = max(0, min(safePageUpperBound, Int(newValue.rounded())))
                if readerMode == .vertical {
                    onJumpToVerticalPage(clamped)
                } else if readerMode == .rtl {
                    currentPage = safePageUpperBound - clamped
                } else {
                    currentPage = clamped
                }
            }
        )
    }

    private var canRenderSlider: Bool {
        totalPages > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(10)
                    .background(AppSurface.readerOverlay, in: Circle())
                    .accessibilityLabel("Back")

                VStack(alignment: .leading, spacing: 2) {
                    Text(chapterTitle.isEmpty ? chapterID : chapterTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(comicTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                Menu {
                    ForEach(ReaderMode.allCases) { mode in
                        Button {
                            onOpenModeMenu?(mode)
                        } label: {
                            Label(mode.title, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image(systemName: "text.justify")
                        .font(.headline)
                        .padding(10)
                        .background(AppSurface.readerOverlay, in: Circle())
                }
                .accessibilityLabel("Reading mode")
                .accessibilityValue(readerMode.title)

                Button("Settings", systemImage: "slider.horizontal.3", action: onOpenSettings)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(10)
                    .background(AppSurface.readerOverlay, in: Circle())
                    .accessibilityLabel("Reader settings")

                Button("Reload", systemImage: "arrow.clockwise", action: onReload)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(10)
                    .background(AppSurface.readerOverlay, in: Circle())
                    .accessibilityLabel("Reload current page")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.72), .black.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: AppSpacing.md) {
                    if previousChapterTitle != nil || nextChapterTitle != nil {
                        chapterButton(
                            title: "Previous chapter",
                            systemImage: "backward.end.fill",
                            enabled: previousChapterTitle != nil,
                            action: onOpenPreviousChapter
                        )
                    }

                    if canRenderSlider {
                        Slider(
                            value: sliderValue,
                            in: 0...Double(safePageUpperBound),
                            step: 1
                        )
                        .id("reader-progress-\(totalPages)")
                        .tint(.white)
                        .animation(animatePageTransitions ? .easeInOut(duration: 0.18) : nil, value: currentPage)
                        .accessibilityLabel("Reading progress")
                        .accessibilityValue("Page \(displayedPageIndex) of \(totalPages)")
                    } else {
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .frame(maxWidth: .infinity)
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.6))
                                    .frame(width: totalPages == 1 ? 28 : 0, height: 4)
                            }
                            .accessibilityHidden(true)
                    }

                    if previousChapterTitle != nil || nextChapterTitle != nil {
                        chapterButton(
                            title: "Next chapter",
                            systemImage: "forward.end.fill",
                            enabled: nextChapterTitle != nil,
                            action: onOpenNextChapter
                        )
                    }
                }

                HStack {
                    Text("\(displayedPageIndex) / \(totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    if !offlineStatusText.isEmpty {
                        Text("• \(offlineStatusText)")
                            .font(.caption2)
                            .foregroundStyle(.green.opacity(0.9))
                    }
                    if totalPages > 0 {
                        let pagesLeft = max(totalPages - displayedPageIndex, 0)
                        if pagesLeft > 0 {
                            Text("• \(pagesLeft) left")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Text(readerMode.title)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.2), .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func chapterButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? .white : .white.opacity(0.45))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

struct DebugLogPanel: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug Logs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines.indices, id: \.self) { idx in
                        Text(lines[idx])
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        .padding(8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ReaderSettingsSheet: View {
    @Binding var mode: ReaderMode
    @Binding var invertTapZones: Bool
    @Binding var preloadDistance: Int
    @Binding var tapZonePreset: TapZonePreset
    @Binding var animatePageTransitions: Bool
    @Binding var readerBackgroundMode: ReaderBackgroundMode
    @Binding var keepScreenOn: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading Direction") {
                    Picker("Mode", selection: $mode) {
                        ForEach(ReaderMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Interaction") {
                    Toggle("Invert left/right tap", isOn: $invertTapZones)
                    Toggle("Animate page transitions", isOn: $animatePageTransitions)
                    Toggle("Keep screen on", isOn: $keepScreenOn)
                    Stepper(value: $preloadDistance, in: 1...8) {
                        Text("Preload nearby pages: \(preloadDistance)")
                    }
                }

                Section("Tap Zones") {
                    Picker("Preset", selection: $tapZonePreset) {
                        ForEach(TapZonePreset.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Background", selection: $readerBackgroundMode) {
                        ForEach(ReaderBackgroundMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                }
            }
            .navigationTitle("Reader Settings")
        }
    }
}
