# Release Checklist

## Build Integrity

Confirm:

1. simulator debug build succeeds
2. release archive succeeds
3. app launches cleanly on a fresh install
4. GitHub Actions produces an unsigned `.ipa` artifact
5. nightly `apps.json` update includes the direct GitHub release `.ipa` URL at the app top level and in the nightly release channel

Recommended command:

```bash
xcodebuild -project ComicDeck.xcodeproj \
  -scheme ComicDeck \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ComicDeckDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Primary User Flows

### Home

Verify:

- continue reading appears after reading activity
- today's reading time updates
- settings and search entry points open correctly

### Discover

Verify:

- source-based browsing loads
- source-scoped search opens from tags or explicit entry points

### Library

Verify:

- bookmarks open
- bookmark and unbookmark from detail works
- shelves open
- shelf create, rename, delete, and reorder work
- adding bookmarks to a shelf works
- source favorites open
- history opens
- downloads open
- recent activity can resume reading

## Reader

1. Chapter opens from detail.
2. Resume from home, history, and library restores chapter and page.
3. `Prev` and `Next` chapter navigation works.
4. Offline reading works when complete local files exist.
5. Incomplete offline chapters do not open as complete offline assets.

## Source Runtime

Verify a representative set of sources:

1. install from repository
2. refresh repository
3. account login where supported
4. web login where supported
5. cookie login where supported
6. source settings save and reload correctly

If testing multiple sources, include:

- one account-login source
- one source with source settings
- one source with comments or extended capabilities

## Library Data

1. favorites persist after relaunch
2. bookmarks, shelves, and shelf memberships persist after relaunch
3. history persists after relaunch
4. restore flows do not introduce duplicate or malformed data
5. resume from history returns through detail before reader
6. bookmarks support batch select, add-to-shelf, and remove
7. shelf filters show the expected subset
8. shelf reorder persists after relaunch

## Tracking

1. AniList OAuth authorization code flow and Bangumi token connection both succeed from `Settings -> Tracking`
2. comic detail can search each connected provider and create a binding
3. manual sync from detail updates the linked AniList or Bangumi entry
4. chapter completion queues a tracker sync and flushes it when the app is active
5. unlink removes the local binding without breaking the comic detail flow
6. tracker tokens are not exported in backup JSON files
7. AniList OAuth callback returns to `comicdeck://anilist-auth`, code exchange succeeds, and the app returns to a usable state

## Downloads and Offline

1. queued tasks appear in `Queue`
2. downloading progress updates visibly
3. completed tasks leave `Queue`
4. completed tasks appear in `Offline`
5. offline items are grouped by comic
6. tapping an offline comic opens the offline comic page
7. complete offline chapters open reader directly and support offline chapter navigation
8. reindex rebuilds the offline library after file changes
9. deleting offline chapters removes local files and indexed records
10. chapter export works as `ZIP`, `CBZ`, `PDF`, and `EPUB`
11. comic export works as `ZIP`, `PDF`, and `EPUB`
12. offline multi-select export works as `ZIP`
13. exported `EPUB` files open in Apple Books without formatting errors
14. importing `.zip` and `.cbz` archives creates offline items and rejects invalid archives clearly

## Backup and Restore

### Local Backup

1. export backup succeeds
2. restore backup succeeds
3. restored bookmarks, shelves, and history match expectations

### WebDAV

1. connection test succeeds
2. configured latest backup upload succeeds
3. timestamped snapshot upload works when enabled
4. remote backup list loads
5. restore configured backup works
6. restore latest remote backup works
7. restore selected remote backup works
8. remote backup deletion works

## Diagnostics and Accessibility

1. debug logs page opens
2. copy, share, and clear actions work
3. release-facing logs do not expose sensitive credentials or cookies
4. Home, Discover, and Library layouts work on iPhone portrait widths
5. light, dark, and system theme switching works
6. list and grid mode switching works where supported
7. icon-only buttons have meaningful accessibility labels
8. reader controls remain within safe areas

## Release State

Confirm:

1. version and build number are updated
2. artifact version label matches `MARKETING_VERSION+CURRENT_PROJECT_VERSION`
3. About shows `Version x.x.x (n)`
4. About shows the expected branch and commit
5. bundle identifier and signing are correct
6. no local-only debug configuration is enabled accidentally
7. release notes mention new features, source compatibility limits, and backup or sync boundaries

## Non-Goals to Reconfirm

Before shipping, reconfirm these are still intentional:

1. offline files are not part of backup or WebDAV sync
2. active download queue state is not restored through backup restore
3. WebDAV sync remains manual rather than background automatic
