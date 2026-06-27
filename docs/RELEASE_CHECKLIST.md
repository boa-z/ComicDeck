# Release Checklist

## Build Integrity

Confirm:

1. simulator debug build succeeds
2. release archive succeeds
3. app launches cleanly on a fresh install
4. GitHub Actions produces an unsigned `.ipa` artifact
5. GitHub Actions produces a native macOS `.dmg` artifact
6. CI verifies the native macOS `.app.zip` contains a complete `ComicDeck.app`
7. nightly release includes `ComicDeck.ipa`, `ComicDeck-macos.dmg`, and `apps.json` release assets
8. nightly `apps.json` update includes the direct GitHub release `.ipa` URL at the app top level and in the nightly release channel
9. AltStore source parsing fields remain present, including `developerName`, `subtitle`, `localizedDescription`, `category`, and top-level source metadata
10. CI verifies the native macOS `.dmg` mounts cleanly and contains `ComicDeck.app` plus an `Applications` shortcut
11. the native macOS target uses `Config/ComicDeckMac.entitlements` for sandbox, network-client, and user-selected-file access

Recommended command:

```bash
xcodebuild -project ComicDeck.xcodeproj \
  -scheme ComicDeck \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ComicDeckDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Native macOS command:

```bash
xcodebuild -project ComicDeck.xcodeproj \
  -scheme ComicDeckMac \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/ComicDeckMacDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For public macOS distribution beyond unsigned nightly artifacts, additionally confirm:

1. `ComicDeck.app` is signed with a Developer ID Application identity
2. the signed app preserves the `Config/ComicDeckMac.entitlements` sandbox/network-client/user-selected-file permissions
3. the `.dmg` is signed with the same Developer ID Application identity
4. the `.dmg` is notarized and stapled
5. CI runs `spctl --assess --type open --context context:primary-signature` against the notarized `.dmg`
6. a fresh install from the signed `.dmg` can complete web login, WebDAV backup/restore, offline import/export, Finder reveal, and reader image drag-out
7. AniList OAuth completes from the native macOS app and returns through the `comicdeck://` callback registered in `Config/ComicDeckMac-Info.plist`
8. notarization failures include the `notarytool` JSON result and Apple notary log in the CI output

GitHub Actions signs and notarizes macOS artifacts only when these repository secrets are configured:

- `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`: password for the `.p12`
- `MACOS_DEVELOPER_ID_APPLICATION`: codesign identity name, for example `Developer ID Application: Team Name (TEAMID)`
- `MACOS_KEYCHAIN_PASSWORD`: optional temporary keychain password
- `MACOS_NOTARY_APPLE_ID`: Apple ID used for notarization
- `MACOS_NOTARY_TEAM_ID`: Apple Developer Team ID
- `MACOS_NOTARY_APP_PASSWORD`: app-specific password for `notarytool`

If all signing and notarization secrets are absent, the workflow still produces unsigned nightly `.app.zip` and `.dmg` artifacts for local verification.
Partial macOS signing or notarization secret configuration fails fast before packaging so release artifacts do not silently mix signed and unsigned states.
The notarization step runs only after the app signing step verifies the signed app's sandbox, network-client, and user-selected-file entitlements.
The signing step also signs nested code in `Contents/Frameworks`, `Contents/PlugIns`, `Contents/XPCServices`, and `Contents/Helpers` before signing the app bundle itself.

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

1. install from a user-provided source index
2. refresh the configured source index
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
