# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common commands
- iOS Simulator build (unsigned):
  ```bash
  xcodebuild -project ComicDeck.xcodeproj \
    -scheme ComicDeck \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/ComicDeckDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build
  ```
- CI packaging for unsigned IPA and Mac Catalyst DMG is defined in `.github/workflows/build.yml` (uses `xcodebuild` archive/build plus `.github/build_github.sh` and `.github/build_macos_dmg.sh`).

## Architecture overview
- Layered dependency flow: `App -> Features -> Runtime -> Core`, with `Features -> Core` as the only shortcut. `Core` must not depend on `Features`.
- App layer (`ComicDeck/App`) bootstraps the app, composes root navigation, and injects shared environment (`MainView`, `ComicDeckApp`, `ContentView`).
- Feature layer (`ComicDeck/Features`) owns SwiftUI screens, feature-local screen models, and in-feature navigation for Home/Discover/Library/etc.
- Runtime layer (`ComicDeck/Runtime`) runs source runtime logic, reader pipeline, downloads/offline indexing, backup/restore/WebDAV sync, and tracking sync.
- Core layer (`ComicDeck/Core`) owns persistent models, SQLite/storage, logging/networking primitives, and bootstrap/localization helpers.
- Design system (`ComicDeck/DesignSystem`) provides shared visual tokens (spacing, surfaces, cards, tint).

## State and data boundaries
- State management uses Observation: feature screen models with `@Observable`, composition with `@State`/`@Bindable`.
- Downloads vs offline: queue state (queued/downloading/failed) is separate from the verified offline library; offline availability must be reconstructable from disk via `OfflineLibraryIndexer`.
- Backup/WebDAV: backups include library data and settings but exclude offline files and the active download queue; WebDAV sync is manual.
- Reader architecture: UI does not load chapters directly; `ReaderSession` owns loading/resume/offline validation; `ReaderImagePipeline` handles image caching outside the view tree.

## Localization
- App-owned UI strings must use `AppLocalization` with semantic keys in `ComicDeck/Resources/Localization/Localizable.xcstrings` (no raw English literals in product screens).
- Follow key naming convention `<feature>.<section>.<element>.<property>` and the `common.*` namespace for shared strings.

## Docs to consult for behavior changes
- `README.md` (overview/build entry)
- `docs/ARCHITECTURE.md` (layering and constraints)
- `docs/USER_GUIDE.md` (expected user flows)
- `docs/TROUBLESHOOTING.md` (debug/recovery paths)
- `docs/LOCALIZATION.md` (string workflow)
- `docs/RELEASE_CHECKLIST.md` (release validation)
- `llms.txt` provides an AI-friendly project map for agents and indexing.
- Documentation policy: update relevant docs alongside product, architecture, persistence, or release workflow changes.
