# ComicDeck

SwiftUI-based iOS and native macOS comic library, discovery, download, and reading app.

## Quick Start

### Requirements

- Xcode with iOS Simulator and macOS SDK support
- iOS and macOS project build tooling available locally

### iOS Build

```bash
xcodebuild -project ComicDeck.xcodeproj \
  -scheme ComicDeck \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ComicDeckDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Native macOS Build

```bash
xcodebuild -project ComicDeck.xcodeproj \
  -scheme ComicDeckMac \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/ComicDeckMacDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Main Entry Points

- `Home`: continue reading, reading activity, shortcuts into discovery and library flows
- `Discover`: source-driven explore, ranking, category, and search entry points
- `Library`: bookmarks, shelves, history, downloads, and offline library

## Features

### Reading

- Resume reading from home, history, and library surfaces
- Navigate between chapters inside the reader
- Prefer offline reading when complete local chapter assets exist
- Persist reading progress and today's reading duration

### Library and Organization

- Save local bookmarks independently of source-side favorites
- Organize bookmarks into reorderable shelves
- Use list and grid layouts for supported library views
- Batch-manage bookmarks and history entries

### Downloads and Offline

- Separate active queue state from verified offline library state
- Group offline chapters by comic
- Reindex offline assets from disk
- Export offline chapters and comics as `ZIP`, `CBZ`, `PDF`, or `EPUB` where supported
- Import validated `ZIP` and `CBZ` archives into the offline library

### Sources and Data

- Manage source repositories, updates, settings, and login flows
- Connect AniList with OAuth client credentials or Bangumi with a personal access token, then link local comics to remote tracking entries
- Sync chapter completion progress from the reader to linked AniList or Bangumi titles
- Back up and restore local library data
- Upload, browse, restore, and delete remote backups through WebDAV
- Localize app-owned UI with String Catalogs and Crowdin

Tracker setup notes:
- AniList requires an OAuth app with `comicdeck://anilist-auth` registered as the redirect URI
- Bangumi currently uses a personal access token entered directly in Settings

## Project Layout

```text
ComicDeck/
  App/             iOS and macOS app entries plus top-level composition
  Core/            Shared models, storage, logging, bootstrap, network helpers
  DesignSystem/    Theme, spacing, surfaces, reusable visual tokens
  Features/        User-facing feature modules
  Runtime/         Source runtime, downloads, reader pipeline, backup/sync services
  Resources/       Localization and bundled assets
  docs/            Project documentation
```

Key feature folders:

- `Features/Home`
- `Features/Discover`
- `Features/Library`
- `Features/Downloads`
- `Features/Reader`
- `Features/Settings`
- `Features/Source`

## Configuration and Release Notes

### Build Metadata

The About screen reads build metadata from the app bundle:

- semantic version and build number
- Git branch name
- short commit ID injected at build time

### GitHub Actions
The repository includes automated workflows in `.github/workflows/`.

- `build.yml`: Builds unsigned iOS `.ipa` artifacts and native macOS `.dmg` artifacts, publishes default-branch and manually requested nightly releases, and attaches the AltStore source manifest to the nightly release.
- `update_source.yml`: Regenerates the AltStore-compatible source manifest (`apps.json`) from the nightly release and uploads it back to the release asset.

Native macOS release notes:
- The macOS artifact is a `.dmg` containing `ComicDeck.app` and an `Applications` shortcut.
- A versioned `.app.zip` artifact is also uploaded for direct inspection and manual packaging.
- By default, local/nightly artifacts are unsigned when Developer ID secrets are not configured.
- When macOS Developer ID and notary secrets are configured in GitHub Actions, CI signs the app, verifies required sandbox/network-client/user-selected-file entitlements, signs and notarizes the `.dmg`, staples the ticket, and runs Gatekeeper assessment.
- Unsigned artifacts may require users to right-click and choose `Open` on first launch.

#### AltStore Installation
You can add ComicDeck to AltStore using the following source URL:
`https://github.com/boa-z/ComicDeck/releases/download/nightly/apps.json`

The nightly release asset is the install source of truth; the repository copy is only the manifest template used by the workflow.

## Documentation

- [Documentation Index](docs/README.md)
- [Architecture](docs/ARCHITECTURE.md)
- [User Guide](docs/USER_GUIDE.md)
- [Localization](docs/LOCALIZATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release Checklist](docs/RELEASE_CHECKLIST.md)

## Documentation Policy

Update documentation in the same change when product behavior, architecture, persistence, or release workflow changes.

- `README.md`: project overview, build entry point, top-level capabilities
- `docs/ARCHITECTURE.md`: system structure, data flow, ownership boundaries
- `docs/USER_GUIDE.md`: user-facing workflows and expected behavior
- `docs/TROUBLESHOOTING.md`: operator and QA recovery paths
- `docs/RELEASE_CHECKLIST.md`: release validation coverage

## Constraints

- WebDAV sync covers backup data, not offline chapter files
- Offline availability is reconstructed from local files and indexing state
- Source compatibility depends on the embedded runtime bridge and source script support level
