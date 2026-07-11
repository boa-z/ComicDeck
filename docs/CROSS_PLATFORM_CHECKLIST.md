# Cross-Platform Checklist

Use this checklist when adding or modifying features that affect both iOS and macOS.

## Feature Entry Points

- [ ] Feature is reachable on both iOS and macOS
- [ ] iOS entry point: TabView tab, NavigationLink, or sheet from MainView
- [ ] macOS entry point: Sidebar destination, NavigationLink, or sheet from MacMainView
- [ ] No platform-specific feature is silently missing from the other platform

## Platform Abstraction

- [ ] Use `PlatformSupport.swift` helpers (`platform*` methods) instead of inline `#if os(macOS)`
- [ ] Use `PlatformImage`, `PlatformFont`, `PlatformColor` typealiases instead of `UIImage`/`NSImage` directly
- [ ] Use `PlatformColors` for semantic background colors
- [ ] Use `PlatformCapabilities` for capability checks instead of scattered `#if os` blocks
- [ ] Sheet presentations on macOS include `minWidth`/`minHeight` via `platformPresentationDetents*`
- [ ] Single shared view has no more than 5 `#if os` blocks; if more, split into Mac-specific view

## UI Layout

- [ ] macOS windows have appropriate `minWidth`/`minHeight` constraints
- [ ] macOS sidebar lists have `minWidth` (typically 190-210)
- [ ] macOS detail panes have `minWidth` (typically 520)
- [ ] macOS uses `NavigationSplitView` for multi-pane layouts
- [ ] macOS uses `ContentUnavailableView` for empty states
- [ ] macOS uses `.formStyle(.grouped)` for settings forms
- [ ] macOS context menus provided for list row actions

## Interaction

- [ ] Touch gestures (tap zones, swipe) work on iOS
- [ ] Keyboard navigation works on macOS (`.onKeyPress` for reader, shortcuts for actions)
- [ ] Mouse/trackpad interactions work on macOS (click, right-click context menus, scroll)
- [ ] macOS menu bar commands considered for key features

## Localization

- [ ] No hardcoded English literals in product screens
- [ ] Use `AppLocalization.text` with semantic keys
- [ ] Key naming follows `<feature>.<section>.<element>.<property>` convention
- [ ] No platform name in localized strings (avoid "for iOS" or "for macOS")
- [ ] New keys added to `Localizable.xcstrings` with English and zh-Hans values

## Reader-Specific

- [ ] Reader keyboard navigation: left/right arrows for pages, up/down for chapters (both platforms)
- [ ] Memory pressure handling: `ReaderPlatformMonitor` handles both platforms
- [ ] Keep-screen-on: iOS only (via `PlatformCapabilities.supportsIdleTimerControl`)
- [ ] Save page: iOS saves to Photos, macOS reveals in Finder
- [ ] Image zoom: iOS uses UIScrollView, macOS uses NSScrollView via NSViewRepresentable (native trackpad pinch / ⌥-scroll zoom; SwiftUI ScrollView + MagnifyGesture was retired to fix a layout-solve feedback loop that pinned main-thread CPU at 100% in the reader)

## Testing

- [ ] New logic has unit tests in `ComicDeckTests/`
- [ ] Tests pass on iOS Simulator
- [ ] Tests pass on macOS (if logic is platform-specific)
- [ ] CI `test` job runs successfully

## Documentation

- [ ] Update `docs/ARCHITECTURE.md` if layer boundaries change
- [ ] Update `docs/USER_GUIDE.md` if user-facing behavior changes
- [ ] Update feature parity matrix in `docs/ARCHITECTURE.md` if feature availability changes

## Current macOS Adaptation Notes

- [x] Main macOS windows define content minimum sizes and desktop-oriented default sizes.
- [x] Global Search, Sources, Tracking, and Downloads have macOS-specific workspace shells.
- [x] Web login uses a macOS container with an explicit minimum size and WebView lifecycle teardown.
- [x] Settings backup/debug export uses a macOS save panel and reveals exported files in Finder.
- [x] WebDAV settings use grouped forms, localized labels, context menus, and destructive confirmation for remote backups.
- [x] Library has a dedicated macOS split-view workspace instead of the shared card/scroll-heavy iOS shell.
- [x] Feature-level keyboard commands cover selected rows for open, delete, copy title/ID, and copy source/reveal/export where applicable. Downloads selected groups/chapters, Search results, Sources rows, Tracking subscription rows, and Library bookmarks/favorites/history rows now share the focused Selection command channel.
- [x] Per-workspace `Cmd+F` focuses local search where the current macOS surface has a searchable list (Search, source-scoped search, Sources, Tracking libraries, and Library bookmarks); otherwise it falls back to opening the global Search window.
- [x] Secondary Library surfaces participate in Selection commands where useful: Shelves rows support open/delete/copy/add-bookmarks, shelf detail bookmarks support open/remove/copy, and Library Overview recent/offline items support resume/copy/reveal actions.
- [x] Reader menu commands cover reload, reading mode, background mode, jump/page actions, and close-window shortcuts.
- [x] macOS drag-and-drop polish covers shelf reordering, Finder drag-out for offline groups/chapters, Library Overview offline tiles, and reader page images.
- [x] Native macOS builds use `Config/ComicDeckMac-Info.plist` for release metadata, the `comicdeck://` OAuth callback scheme, and a macOS-only `AppIconMac` asset set so macOS asset compilation does not inherit iOS/watchOS icon entries.
- [x] The macOS `Cmd+,` settings command opens the native Settings scene consistently from the main, search, and other command-enabled windows; the sidebar Settings destination remains available for in-window browsing.
- [x] macOS Home shortcuts switch to native Downloads and Sources workspaces, and root destinations avoid nested `NavigationStack` containers.
