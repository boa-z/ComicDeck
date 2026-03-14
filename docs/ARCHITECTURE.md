# Architecture

## Overview

ComicDeck is a SwiftUI app with clear separation between user-facing features, runtime services, and shared infrastructure.

Primary dependency flow:

```text
App
  -> Features
     -> Runtime
        -> Core
```

Allowed shortcut:

```text
Features -> Core
```

Constraint:

- `Core` must not depend on `Features`

## Product Composition

`MainView` composes the top-level product areas.

### Primary Destinations

- `Home`: reading resume, activity summary, and quick actions
- `Discover`: source-driven browsing, ranking, category, and search entry
- `Library`: bookmarks, shelves, history, downloads, and offline assets

### Secondary Flows

- `Search`
- `Settings`
- `Source management`
- `Debug logs`

## Layers

### App Layer

Location:

- `ComicDeck/App`

Responsibilities:

- bootstrap the app
- compose root navigation
- inject shared environment and global flows

Important files:

- `MainView.swift`
- `ComicDeckApp.swift`
- `ContentView.swift`

### Feature Layer

Location:

- `ComicDeck/Features`

Responsibilities:

- render user-facing SwiftUI screens
- own feature-local screen models
- manage in-feature navigation and presentation

Current feature domains:

- `Home`
- `Discover`
- `Library`
- `Downloads`
- `Favorites`
- `Detail`
- `Reader`
- `Search`
- `Settings`
- `Source`
- `Login`

Constraint:

- feature views should not embed source runtime parsing or low-level storage logic directly

### Runtime Layer

Location:

- `ComicDeck/Runtime`

Responsibilities:

- execute source runtime logic
- manage source repositories, settings, and login flows
- run reader loading and image pipeline behavior
- manage download queue execution and offline indexing
- handle backup, restore, export, import, and WebDAV sync

Important files:

- `SourceRuntime.swift`
- `ComicDownloadManager.swift`
- `OfflineLibraryIndexer.swift`
- `OfflineExportService.swift`
- `OfflineImportService.swift`
- `ReaderImagePipeline.swift`
- `ReaderViewModel.swift`
- `AppBackupService.swift`
- `WebDAVSyncService.swift`

### Core Layer

Location:

- `ComicDeck/Core`

Responsibilities:

- define persistent models
- wrap SQLite and secure storage
- provide logging and networking primitives
- expose bootstrap and localization helpers

Important subfolders:

- `Core/Models`
- `Core/Storage`
- `Core/Logging`
- `Core/Bootstrap`
- `Core/Network`
- `Core/Localization`

## State Management

ComicDeck primarily uses modern Observation.

- Feature screen models use `@Observable`
- Root and composition state use `@State` and `@Bindable`
- Older `ObservableObject` usage has been reduced

State ownership rules:

1. Feature UI state stays inside the relevant feature screen model.
2. Runtime services expose capabilities and long-lived operational state.
3. Persistent truth lives in SQLite, local files, or explicitly indexed offline assets.

Examples:

- `HomeScreenModel` formats home-specific presentation data
- `DownloadManagerScreenModel` shapes queue and offline state into grouped UI sections
- `LibraryViewModel` owns library snapshots shared across related flows

`LibraryViewModel` also owns:

- library categories
- favorite-to-category memberships
- backup payload generation for library organization data

## Reader Architecture

Reader is split across composition, session state, rendering, and pipeline concerns.

Key files:

- `ComicReaderView.swift`
- `ReaderSession.swift`
- `ReaderCanvasView.swift`
- `ReaderChromeView.swift`
- `ReaderImagePipeline.swift`

Design intent:

- UI does not load chapter content directly
- reader session owns chapter loading, resume, and offline validation
- image caching and page loading stay outside the view tree

## Downloads and Offline

Queue state and offline state are intentionally distinct.

### Queue

Represents:

- queued
- downloading
- failed

Backed by:

- runtime queue state
- persistent download task records

### Offline Library

Represents:

- verified local chapter assets
- comic-grouped offline inventory
- complete chapters available for offline reading
- imported archive content under an `imported` offline namespace

Backed by:

- local file system
- metadata files
- `OfflineLibraryIndexer`
- `OfflineExportService`

Design intent:

- completed downloads leave queue semantics behind
- offline availability must be reconstructable from disk
- offline reading follows the standard comic -> chapter -> reader flow

## Localization Architecture

ComicDeck uses:

- `AppLocalization` for semantic key lookup in Swift code
- `Localizable.xcstrings` as the source of truth for app-owned UI
- `crowdin.yml` for translation sync

Design intent:

- use stable semantic keys instead of raw UI literals
- keep source-provided content outside app-owned localization
- update localization assets together with user-facing feature changes

## Library Organization

Library organization is intentionally separate from source-side favorites and folders.

Persistent models:

- `FavoriteComic` for local bookmarks
- `LibraryCategory` for bookmark shelves
- bookmark-to-shelf memberships

Storage tables:

- `favorites`
- `favorite_categories`
- `favorite_category_memberships`

## Deliberate Constraints

- WebDAV sync handles backup data, not offline chapter files
- Active download queue state is not the source of truth for offline availability
- Source compatibility is bounded by the embedded runtime bridge and supported script behavior
- source favorites remain source-runtime specific
- local bookmarks represent app-side saved comics
- local library shelves organize bookmarks at the app layer
- category membership is many-to-many, so a comic can appear in multiple shelves
- shelf order is persisted through `sort_order`
- bookmark pages can filter by shelf without mutating the underlying bookmark set
- shelf management is a secondary flow launched from the bookmarks page, not a peer library destination

## Backup and Sync

Backup is data-oriented, not file-oriented.

Included:
- favorites
- favorite categories and memberships
- reading history
- app preferences
- reader preferences
- source runtime preferences
- source settings store

Excluded:
- offline files
- active download queue
- transient runtime cache

WebDAV sync currently supports:
- connection verification
- upload configured latest backup
- optional timestamped snapshots
- remote backup listing
- restore configured backup
- restore latest remote backup
- restore a selected remote snapshot
- delete remote snapshots

## Design System

Location:
- `ComicDeck/DesignSystem`

Responsibilities:
- spacing
- radius
- surfaces
- tint choices
- shared card presentation

This keeps the app visually consistent across:
- home cards
- library cards
- source management cards
- detail sections

## Current Tradeoffs

1. Search and settings are still presented as secondary sheets rather than a single global router.
2. WebDAV sync is manual and explicit, not background-automatic.
3. Offline files are not synchronized remotely.
4. Source compatibility still depends on runtime bridge coverage per script capability.

## Next Structural Candidates

The next architecture-level improvements that would matter most are:

1. a lightweight global app router for detail / reader / search / settings
2. batch add-to-category from local favorites surfaces
3. category sorting / manual reorder
3. richer download policies and retry flows
4. backup merge/version handling beyond full restore
