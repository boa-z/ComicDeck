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
- `Tracking`
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
- handle tracker account state, remote binding, and queued sync events

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
- `Runtime/HtmlRuntimeBridge.swift`
- `Runtime/HtmlDOM`
- `Runtime/Tracker`

### Core Layer

Location:

- `ComicDeck/Core`

Responsibilities:

- define persistent models
- wrap SQLite and secure storage
- provide logging and networking primitives
- expose bootstrap and localization helpers

Persistence implementation:

- `CoreBootstrap` opens the app database at `database/source_runtime.sqlite3`
- `SQLiteStore` remains the stable actor facade used by Runtime and Features
- `Core/Storage` now uses GRDB internally for SQLite access, configuration, and versioned migrations
- migrations preserve the existing table names and data contracts used by favorites, history, downloads, offline indexing, and tracker sync

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
- backup payload generation for library organization data and tracker backup state

`TrackerViewModel` owns:

- connected tracker accounts
- per-comic tracker bindings
- pending sync queue state
- configurable automatic and manual sync direction preferences
- local-to-remote progress dispatch across all bound providers
- best-effort remote-to-local pull through confirmed bindings and loaded local chapter lists
- on-demand provider manga-list loading for Library tracking workspaces

## Source Script HTML Runtime

Source scripts keep using the same JS-facing DOM contract exposed by `ComicSourceScriptEngine`:

- `Html.parse`
- `Html.querySelector`
- `Html.querySelectorAll`
- `Html.getElementById`
- `Html.elementQuerySelector`
- `Html.elementQuerySelectorAll`
- `Html.children`
- `Html.text`
- `Html.innerHTML`
- `Html.attributes`
- `Html.dispose`
- JS wrappers `HtmlDocument` and `HtmlElement`

Implementation details now live fully inside the Runtime layer.

Key files:

- `Runtime/HtmlRuntimeBridge.swift`
- `Runtime/HtmlDOM/HtmlRuntimeEngine.swift`
- `Runtime/HtmlDOM/HtmlDocumentStore.swift`
- `Runtime/HtmlDOM/HtmlDOM.swift`
- `Runtime/HtmlDOM/HtmlParser.swift`
- `Runtime/HtmlDOM/HtmlSelectorEngine.swift`
- `Runtime/HtmlDOM/HtmlSerializer.swift`

Design intent:

- source-script HTML parsing is fully in-process
- runtime HTML parsing does not depend on a hidden `WKWebView`
- DOM queries stay synchronous from the JS bridge point of view
- parsing runs on the existing runtime engine queue rather than the main thread
- document and element handles preserve the compatibility behavior expected by installed scripts

The visible login sheet web view remains a separate feature-layer concern for interactive login and cookie capture.

## Reader Architecture

Reader is split across composition, session state, rendering, and pipeline concerns.

Key files:

- `ComicReaderView.swift`
- `ReaderSession.swift`
- `ReaderCanvasView.swift`
- `ReaderChromeView.swift`
- `ReaderPageView.swift`
- `ReaderGestureInteraction.swift`
- `ReaderImagePipeline.swift`

Reader interaction model:

- `ReaderGestureInteraction.swift` centralizes single-tap, double-tap, and long-press disambiguation with a delayed single-tap dispatch to avoid conflicts with double-tap zoom
- tap zones use an edge-biased resolver: horizontal mode defaults to left/center/right regions (30%/40%/30%) and stores a user-configurable horizontal turn margin; vertical mode uses narrow edge zones with center tap toggling chrome
- long press on a page temporarily zooms to 1.75x centered on the press point; releasing restores the original scale
- top chrome uses a single `More` menu instead of multiple trailing buttons
- bottom status bar shows priority-based information (loading state > translation status > offline indicator)

Design intent:

- UI does not load chapter content directly
- reader session owns chapter loading, resume, and offline validation
- remote reader loading now prepares a chapter request session once, allocates fixed absolute page slots, resolves the initial visible page first, and fills nearby pages in background batches
- installed source scripts keep the same `comic.loadEp(...)` and optional `comic.onImageLoad(...)` contract for both eager and progressive paths
- downloads and offline flows still use the existing eager full-request resolution path, while the reader uses the additive progressive request-session path
- image caching and page-byte loading stay outside the view tree in `ReaderImagePipeline`; progressive loading only changes how `ImageRequest` values are generated
- current-page export loads the selected page through `ReaderImagePipeline`, decodes with the shared decoded-image store, and renders translation overlays when the translated view is active

### Reader Translation

Page translation is layered on top of the existing reader session and document pipeline.

Design intent:

- the built-in backend uses ComicDeck-managed translation services within the reader pipeline
- the Koharu backend still uses the existing Koharu document translation pipeline rather than a separate model-selection request path
- when Koharu page translation is enabled, ComicDeck bridges Koharu model selection through `DELETE /llm` or `PUT /llm` global configuration calls before requesting translation
- Koharu cache partitioning includes a normalized representation of the active Koharu configuration so new reader sessions do not reuse documents created under a different server-side LLM setup

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

## Tracking

Tracking is intentionally binding-first:

- provider support: `AniList`, `Bangumi`
- auth model:
  - `AniList`: OAuth authorization code flow with the `comicdeck://anilist-auth` callback
  - `Bangumi`: personal access token entered in Settings
- sync directions: local-to-remote push, remote-to-local pull, and two-way comparison
- sync triggers: reader chapter completion, manual sync from comic detail, and manual sync from tracker library detail
- reader completion calls `TrackerViewModel.recordChapterCompletion(...)`, which respects automatic sync settings and dispatches to every bound provider instead of hardcoding a single tracker

Persistent tracker state is split into:

- `tracker_accounts`
- `tracker_bindings`
- `tracker_sync_events`

Design intent:

- local reader completion is a local-to-remote event and never triggers an automatic pull
- manual pull and two-way sync only operate through confirmed `tracker_bindings`
- remote pulls load the provider manga list, match the existing remote media ID, refresh binding metadata, and update local `history` only when the local chapter sequence is available
- automatic bidirectional sync must not lower local history; manual pull can let the remote value win while clamping to the local chapter list
- failed push attempts stay queued for the next flush while the app is active
- tracker tokens stay in Keychain during normal runtime and are copied into app backup JSON so local/WebDAV restores can recover tracker sign-in state
- AniList OAuth client IDs are stored in user defaults because they are public configuration, while AniList access tokens and client secrets stay in Keychain during normal runtime
- tracker library workspaces fetch remote manga lists on demand through `TrackerViewModel` and provider clients instead of persisting a separate remote-list cache
- AniList lists come from `AniListTrackerClient` GraphQL collection loading; Bangumi lists come from `BangumiTrackerClient` collection loading
- tracker library list pages stay remote-entry focused; local multi-source progress display is deferred to detail pages
- local multi-source progress display is derived from existing `tracker_bindings` rows grouped by `sourceKey` and `comicID`
- tracker library detail pages show all confirmed bindings side-by-side and can add more source bindings to the same remote tracker entry through explicit user-selected source search, but do not recommend comics or automatically match sources
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
- tracker accounts, bindings, sync preferences, and access tokens

Excluded:
- offline files
- active download queue
- pending tracker sync events
- transient runtime cache

Backup JSON can contain plaintext tracker access tokens. WebDAV remains a transport layer over `AppBackupPayload`; it does not read tracker storage directly.

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
