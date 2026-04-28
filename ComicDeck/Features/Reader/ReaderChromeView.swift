import SwiftUI

struct ReaderOverlayView: View {
    let chapterTitle: String
    let chapterID: String
    let comicTitle: String
    let offlineStatusText: String
    let displayedPageIndex: Int
    let totalPages: Int
    let resolvedPageCount: Int
    let isLoadingMore: Bool
    let translationEnabled: Bool
    let translationShowOriginal: Bool
    let translationStatusText: String?
    let isTranslatingCurrentPage: Bool
    let onTranslateCurrentPage: (() -> Void)?
    let onToggleTranslationShowOriginal: (() -> Void)?
    let translationBackendKind: ReaderTranslationBackendKind
    let readerMode: ReaderMode
    let animatePageTransitions: Bool
    @Binding var currentPage: Int
    let previousChapterTitle: String?
    let nextChapterTitle: String?
    let onDismiss: () -> Void
    let onOpenModeMenu: ((ReaderMode) -> Void)?
    let onOpenSettings: () -> Void
    let onReload: () -> Void
    let onShareCurrentPage: (() -> Void)?
    let onSaveCurrentPage: (() -> Void)?
    let isExportingCurrentPage: Bool
    let onOpenPreviousChapter: () -> Void
    let onOpenNextChapter: () -> Void
    let onJumpToVerticalPage: (Int) -> Void

    private var safePageUpperBound: Int {
        max(totalPages - 1, 0)
    }

    private var normalizedDisplayedPageIndex: Int {
        guard totalPages > 0 else { return 0 }
        return min(max(displayedPageIndex, 1), totalPages)
    }

    private var progressSummaryText: String {
        AppLocalization.format(
            "reader.pages",
            "%lld/%lld pages",
            Int64(normalizedDisplayedPageIndex),
            Int64(totalPages)
        )
    }


    private var loadingStatusText: String? {
        guard isLoadingMore else { return nil }
        return AppLocalization.text("reader.status.loading_more", "Loading more pages")
    }

    private var secondaryStatusText: String? {
        if let loadingStatusText {
            return loadingStatusText
        }
        if translationEnabled, let translationStatusText, !translationStatusText.isEmpty {
            return translationStatusText
        }
        if !offlineStatusText.isEmpty {
            return offlineStatusText
        }
        return nil
    }

    private var secondaryStatusIcon: String? {
        if isLoadingMore {
            return "arrow.down.circle"
        }
        if translationEnabled, let translationStatusText, !translationStatusText.isEmpty {
            return "text.bubble"
        }
        if !offlineStatusText.isEmpty {
            return "checkmark.circle"
        }
        return nil
    }

    @State private var sliderState = ReaderProgressSliderState()

    private var resolvedSliderValue: Double {
        ReaderProgressSliderMapper.displayValue(
            currentPage: currentPage,
            totalPages: totalPages,
            readerMode: readerMode
        )
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                guard totalPages > 0 else { return 0 }
                return sliderState.displayValue(currentValue: resolvedSliderValue)
            },
            set: { newValue in
                guard totalPages > 0 else { return }
                sliderState.updateDragValue(newValue)
                if sliderState.isDragging { return }
                applySliderValue(newValue)
            }
        )
    }

    private var sliderDragPageText: String {
        let targetPage = ReaderProgressSliderMapper.currentPage(
            for: sliderState.dragValue,
            totalPages: totalPages,
            readerMode: readerMode
        )
        let displayPage = ReaderProgressSliderMapper.displayValue(
            currentPage: targetPage,
            totalPages: totalPages,
            readerMode: readerMode
        ) + 1
        return AppLocalization.format(
            "reader.pages",
            "%lld/%lld pages",
            Int64(displayPage),
            Int64(totalPages)
        )
    }

    private func applySliderValue(_ newValue: Double) {
        let targetPage = ReaderProgressSliderMapper.currentPage(
            for: newValue,
            totalPages: totalPages,
            readerMode: readerMode
        )
        if readerMode == .vertical {
            onJumpToVerticalPage(targetPage)
        } else {
            currentPage = targetPage
        }
    }

    private var canRenderSlider: Bool {
        totalPages > 1
    }

    private var moreMenu: some View {
        Menu {
            Section(AppLocalization.text("reader.chrome.mode", "Mode")) {
                ForEach(ReaderMode.allCases) { mode in
                    Button {
                        onOpenModeMenu?(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }

            Button {
                onOpenSettings()
            } label: {
                Label(
                    AppLocalization.text("reader.settings.navigation_title", "Reader Settings"),
                    systemImage: "slider.horizontal.3"
                )
            }

            Section(AppLocalization.text("reader.chrome.page", "Page")) {
                if let onShareCurrentPage {
                    Button(action: onShareCurrentPage) {
                        Label(
                            AppLocalization.text("reader.action.share_current_page", "Share current page"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(isExportingCurrentPage)
                }

                if let onSaveCurrentPage {
                    Button(action: onSaveCurrentPage) {
                        Label(
                            AppLocalization.text("reader.action.save_current_page", "Save current page"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .disabled(isExportingCurrentPage)
                }

                Button {
                    onReload()
                } label: {
                    Label(
                        AppLocalization.text("reader.action.reload_page", "Reload current page"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }

            if translationEnabled, let onTranslateCurrentPage {
                Button(action: onTranslateCurrentPage) {
                    Label(
                        AppLocalization.text(
                            translationBackendKind == .koharu
                                ? "reader.translation.action.current_page.koharu"
                                : "reader.translation.action.current_page",
                            translationBackendKind == .koharu ? "Translate current page with Koharu" : "Translate current page"
                        ),
                        systemImage: translationShowOriginal ? "text.word.spacing" : "character.book.closed"
                    )
                }
                .disabled(isTranslatingCurrentPage)
            }

            if translationEnabled, let onToggleTranslationShowOriginal {
                Button(action: onToggleTranslationShowOriginal) {
                    Label(
                        AppLocalization.text(
                            "reader.translation.toggle",
                            translationShowOriginal ? "Show translated" : "Show original"
                        ),
                        systemImage: translationShowOriginal ? "eye" : "eye.slash"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .padding(10)
                .background(AppSurface.readerOverlay, in: Circle())
        }
        .accessibilityLabel(AppLocalization.text("common.more", "More"))
        .accessibilityValue(readerMode.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(AppLocalization.text("common.back", "Back"), systemImage: "chevron.left", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(10)
                    .background(AppSurface.readerOverlay, in: Circle())
                    .accessibilityLabel(AppLocalization.text("common.back", "Back"))

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

                moreMenu
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
                            title: AppLocalization.text("reader.action.previous_chapter", "Previous chapter"),
                            systemImage: "backward.end.fill",
                            enabled: previousChapterTitle != nil,
                            action: onOpenPreviousChapter
                        )
                    }

                    if canRenderSlider {
                        ZStack(alignment: .top) {
                            if sliderState.isDragging {
                                Text(sliderDragPageText)
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(AppSurface.readerOverlay, in: Capsule())
                                    .offset(y: -30)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    .accessibilityHidden(true)
                            }

                            Slider(
                                value: sliderValue,
                                in: 0...Double(safePageUpperBound),
                                step: 1
                            ) { editing in
                                if editing {
                                    sliderState.beginDragging(initialValue: resolvedSliderValue)
                                } else {
                                    sliderState.endDragging()
                                    applySliderValue(sliderState.dragValue)
                                }
                            }
                            .id("reader-progress-\(totalPages)")
                            .tint(.white)
                            .animation(animatePageTransitions ? .easeInOut(duration: 0.18) : nil, value: currentPage)
                            .accessibilityLabel(AppLocalization.text("reader.progress.label", "Reading progress"))
                            .accessibilityValue(progressSummaryText)
                            .onChange(of: resolvedSliderValue) { _, value in
                                sliderState.syncAfterExternalPageChange(currentValue: value)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .animation(animatePageTransitions ? .easeInOut(duration: 0.16) : nil, value: sliderState.isDragging)
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
                            title: AppLocalization.text("reader.action.next_chapter", "Next chapter"),
                            systemImage: "forward.end.fill",
                            enabled: nextChapterTitle != nil,
                            action: onOpenNextChapter
                        )
                    }
                }

                HStack(spacing: 6) {
                    Text(progressSummaryText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.88))

                    if let secondaryStatusText {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                        if let secondaryStatusIcon {
                            Image(systemName: secondaryStatusIcon)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        Text(secondaryStatusText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }

                    Spacer()
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
            Text(AppLocalization.text("reader.debug.logs", "Debug Logs"))
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
    @Binding var tapTurnMargin: Double
    @Binding var animatePageTransitions: Bool
    @Binding var readerBackgroundMode: ReaderBackgroundMode
    @Binding var keepScreenOn: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalization.text("reader.settings.mode", "Reading Direction")) {
                    Picker(AppLocalization.text("reader.chrome.mode", "Mode"), selection: $mode) {
                        ForEach(ReaderMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(AppLocalization.text("reader.settings.interaction", "Interaction")) {
                    Toggle(AppLocalization.text("reader.settings.invert_tap", "Invert left/right tap"), isOn: $invertTapZones)
                    Toggle(AppLocalization.text("reader.settings.animate", "Animate page transitions"), isOn: $animatePageTransitions)
                    Toggle(AppLocalization.text("reader.settings.keep_screen_on", "Keep screen on"), isOn: $keepScreenOn)
                    Stepper(value: $preloadDistance, in: 1...8) {
                        Text(AppLocalization.format("reader.preload_distance", "Preload nearby pages: %lld", Int64(preloadDistance)))
                    }
                }

                Section(AppLocalization.text("reader.settings.preset", "Tap Zones")) {
                    Picker(AppLocalization.text("reader.chrome.preset", "Preset"), selection: $tapZonePreset) {
                        ForEach(TapZonePreset.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(AppLocalization.text("reader.settings.tap_turn_margin", "Turn margin"))
                            Spacer()
                            Text(AppLocalization.format("reader.settings.tap_turn_margin.value", "%lld%%", Int64((tapTurnMargin * 100).rounded())))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $tapTurnMargin, in: 0.20...0.45, step: 0.05)
                    }
                    Text(AppLocalization.text("reader.settings.tap_turn_margin.footer", "Controls how much of each screen edge turns pages in Automatic and Edge-Biased horizontal tap zones."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(AppLocalization.text("reader.settings.appearance", "Appearance")) {
                    Picker(AppLocalization.text("reader.background.mode", "Background"), selection: $readerBackgroundMode) {
                        ForEach(ReaderBackgroundMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                }

            }
            .navigationTitle(AppLocalization.text("reader.settings.navigation_title", "Reader Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.text("common.done", "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
