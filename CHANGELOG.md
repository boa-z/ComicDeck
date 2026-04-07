# Changelog

All notable changes to ComicDeck will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Storage**: Migrated `SQLiteStore` internals from raw `SQLite3` C API to [GRDB](https://github.com/groue/GRDB.swift), replacing ad hoc schema setup with a `DatabaseMigrator`-based versioned migration system. Public actor API and database file path are unchanged. ([Core/Storage/SQLiteStore.swift])
- **Reader**: Moved offline chapter file scanning (`loadLocalImageRequests`) off the MainActor into a `Task.detached` to eliminate UI freezes when opening large offline chapters. ([Features/Reader/ReaderSession.swift])
- **Reader**: Page resolution now preserves proximity-based priority ordering instead of losing it through `Set` conversion and ascending re-sort. Nearby pages load before distant ones. ([Features/Reader/ReaderSession.swift])
- **Reader**: Slider in vertical scroll mode no longer fires scroll commands during drag; scrolling commits only on drag end. ([Features/Reader/ReaderChromeView.swift])
- **Reader**: Replaced deprecated `UIScreen.main.scale` with `@Environment(\.displayScale)` in `PlainRemoteImage`, `ReaderPageView`, and `ZoomableRemoteImage.Coordinator`. ([Features/Reader/ReaderCanvasView.swift])
- **Reader**: `ReaderImagePrefetcher` is now annotated `@MainActor` for thread safety. ([Features/Reader/ComicReaderView.swift])
- **Reader**: `OfflineChapterLoadError` descriptions now use `AppLocalization` for localization support. ([Features/Reader/ReaderSession.swift])
- **Pipeline**: Removed dead `URLRequest.cachePolicy` setting that had no effect because the pipeline's `URLSession` uses `urlCache = nil`. ([Runtime/ReaderImagePipeline.swift])

### Fixed

- **Reader**: `onDisappear` cleanup (history save, session close, tracker sync) is now wrapped in `UIApplication.beginBackgroundTask` to prevent data loss when the app backgrounds immediately after dismissing the reader. ([Features/Reader/ComicReaderView.swift])
- **Reader**: Adjacent chapter navigation now checks `integrityStatus == .complete` before loading an offline chapter, preventing partially-downloaded chapters from being opened. ([Features/Reader/ReaderSession.swift])
- **Reader**: Offline spotlight on the Home screen now passes the `chapterSequence` to the reader, enabling prev/next chapter navigation when reading offline from Home. ([Features/Home/HomeView.swift])
- **Reader**: Fixed potential strong reference cycle in `ZoomableRemoteImage.Coordinator` by using `[weak self]` in the image loading Task. ([Features/Reader/ReaderCanvasView.swift])
- **Reader**: Added a Done button to `ReaderSettingsSheet` for accessibility and swipe-dismiss parity. ([Features/Reader/ReaderChromeView.swift])
- **Navigation**: Fixed `LibraryViewModel` environment not being forwarded through Discover and Detail navigation chains, causing a fatal crash when navigating to `ComicDetailView` from explore/category/search flows. ([Features/Discover/DiscoverView.swift], [Features/Detail/ComicDetailView.swift])

### Removed

- Unused `import CryptoKit` in `ComicReaderView.swift`.
