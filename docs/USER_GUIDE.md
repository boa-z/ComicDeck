# User Guide

## Overview

ComicDeck is organized around three primary areas and several supporting flows.

### Primary Areas

- `Home`: resume reading, review activity, and jump into high-frequency actions
- `Discover`: browse source content through explore, category, ranking, and search flows
- `Library`: manage bookmarks, shelves, history, downloads, and offline content

### Supporting Flows

- `Search`
- `Settings`
- `Sources`
- `Debug Logs`

## Getting Started

### Install and Select Sources

1. Open `Home`.
2. Open `Settings`.
3. Open `Sources`.
4. Open `Source Index`.
5. Enter your own `index.json` URL.
6. Refresh or load available source definitions.
7. Install the sources you want to use.

Installed sources can then be:

- selected as active
- updated
- configured
- logged into where supported

### Find Comics

You can discover content in two main ways.

`Search`:

- open global search from `Home` or `Discover`
- run source-aware searches

`Discover`:

- browse explore surfaces for the active source
- open categories and rankings
- enter source-scoped search from discovery flows

## Reading

### Continue Reading

ComicDeck keeps reading history and resume points.

Resume entry points:

- `Home`
- `Library -> Recent Activity`
- `History`

Resume behavior:

- if a valid saved chapter exists, the app reopens that chapter and page
- if the chapter is fully downloaded, the app prefers offline reading
- if history is too old to map safely to a chapter, the app falls back to the comic detail page

### Reader Controls

Inside the reader you can:

- move between pages by tapping the left or right edge of the screen (horizontal mode) or the center area toggles the chrome overlay
- double tap to zoom into a page around the tap location; double tap again to zoom out
- long press a page to temporarily zoom to 1.75x centered on the press point; release to snap back
- switch chapters with `Prev` and `Next`
- scrub with the progress slider; a floating page indicator appears while dragging
- open the `More` menu (top-right ellipsis) for mode switching, reader settings, reload, translation controls, and current-page share/save actions

Tap zones in horizontal mode use an edge-biased layout by default: the left 30% navigates backward, the right 30% navigates forward, and the center 40% toggles the control overlay. Reader Settings can change the horizontal turn margin from 20% to 45%; vertical mode keeps conservative center-only chrome toggling with narrow edges reserved for system gestures.

While a chapter is still resolving, unresolved pages show static preparing placeholders and may show how many pages are ready. Downloaded chapters show offline status in the bottom reader chrome. If an offline chapter is incomplete or missing, the reader shows an explicit offline error instead of silently switching back to network loading.

## Library Management

### Bookmarks and Shelves

Bookmarks are local app-side saved comics. They are separate from source-side favorites.

Supported actions:

- view bookmarks in `List` or `Grid`
- open comic detail
- bookmark or unbookmark from comic detail
- remove bookmarks directly from the list
- enter `Select` mode for batch actions
- add selected bookmarks to a shelf
- remove selected bookmarks in one step
- filter bookmarks by shelf
- create, rename, delete, and reorder shelves

### Tracking

In `Settings -> Tracking` you can:

- connect AniList by entering an AniList OAuth client ID and client secret, then authorizing in the system browser
- connect Bangumi with a personal access token
- verify the current connection
- disconnect either provider

AniList setup:

1. Create an AniList OAuth app.
2. Register `comicdeck://anilist-auth` as the redirect URI.
3. Copy the AniList client ID and client secret into `Settings -> Tracking`.
4. Tap `Authorize AniList` and finish the browser flow.

In comic detail you can:

- link the local comic to an AniList or Bangumi entry
- manually sync current progress
- unlink an existing tracker entry

Open `Library -> AniList Library` or `Library -> Bangumi Library` to view the connected provider's manga list. Each tracker library workspace loads remote list entries on demand, shows only confirmed local source bindings, and displays progress for every tracker provider already bound to the same local comic. Unbound rows can launch a manual search in the currently selected source. Use comic detail for linking, syncing, and unlinking; tracker library pages do not recommend comics, automatically match sources, or write remote list data to a separate cache in v1.

Reader behavior:

- when you finish a linked chapter, ComicDeck queues a tracker sync
- pending syncs are retried when the app becomes active again
- tracker tokens stay on-device and are not included in backup exports
- AniList OAuth uses the callback URL `comicdeck://anilist-auth`; register it in your AniList app before authorizing
- AniList client secrets are stored locally in Keychain and are not included in backup exports

### Source Favorites

Open `Library -> Favorites` when you need to work with source-owned favorites or folders.

Typical uses:

- browse favorites from the active source
- switch source favorite folders
- remove items from source-side favorites

### History

History stores recent reading progress.

You can:

- reopen a comic
- resume directly
- batch delete history records

## Downloads and Offline

ComicDeck separates active downloads from verified offline assets.

### Queue

Queue shows:

- queued tasks
- downloading tasks
- failed tasks

Use Queue to:

- monitor download progress
- clear queue items
- remove failed tasks

### Offline Library

Offline shows completed local chapter assets grouped by comic.

Use Offline to:

- import `.zip` or `.cbz` archives
- open an offline comic page
- read complete chapters directly
- use `Resume Offline`
- inspect local chapter files when needed
- export chapters as `ZIP`, `CBZ`, `PDF`, or `EPUB`
- export a whole comic as `ZIP`, `PDF`, or `EPUB`
- reindex the offline library
- delete downloaded chapters
- export multi-selected chapters as `ZIP`

Archive import rules:

- only `ZIP` and `CBZ` are supported
- archives must contain readable image files
- encrypted or unsupported ZIP variants are rejected
- each imported archive becomes one offline comic entry
- imported offline comics are marked as `Imported`
- imported offline comics can be renamed from the offline comic page

### Reindex

Use `Reindex` when:

- local files were changed manually
- offline items look incorrect
- completed chapters are missing from the offline list

## Backup and Restore

### Local Backup

In `Settings -> Data` you can:

- export a backup file
- restore a backup file

Included in backups:

- bookmarks
- library shelves and memberships
- history
- app and reader preferences
- source runtime preferences
- source settings

Not included:

- offline chapter files
- active download queue

### WebDAV Sync

In `Settings -> Data -> WebDAV Sync` you can:

- configure a WebDAV directory
- test the connection
- upload the configured latest backup
- optionally upload timestamped snapshots
- list remote backups
- restore the configured backup
- restore the latest remote backup
- restore a specific remote backup
- delete remote backup snapshots

## Sources

Installed sources can expose:

- account login
- web login
- cookie login
- source settings

On a source detail page you can:

- set the source as active
- update it
- delete it
- change source-specific settings
- complete supported login flows

## Appearance and Diagnostics

### Settings

In `Settings` you can configure:

- app theme
- list or grid layouts for supported pages
- reader cache maintenance

### Page Translation

In `Settings -> Translation` you can configure how ComicDeck translates reader pages.

Available backends:

- `Built-in`: uses the app's native page translation path
- `Koharu`: sends translation work through a Koharu server

Koharu-specific options:

- set the Koharu server URL
- choose the Koharu LLM mode: `Server default`, `Provider`, or `Local`
- when using `Provider` or `Local`, optionally set provider ID, model ID, temperature, max tokens, and a custom system prompt

Important limitation:

- Koharu LLM settings update the Koharu server's global `/llm` state before page translation starts
- ComicDeck does not send a private per-request LLM override for each translation job
- changing these settings clears cached page translation state for new reader sessions that use the Koharu backend

### Debug Logs

In `Settings -> Debug Logs` you can:

- enable or disable debug logging
- filter logs
- inspect source, download, and sync failures
- copy visible logs
- share the log file
- clear logs

Use this when investigating:
- source runtime failures
- login problems
- download behavior
- WebDAV sync issues

In `Settings -> About` you can confirm:
- `Version x.x.x (n)`
- the current Git branch and short commit ID for that build
