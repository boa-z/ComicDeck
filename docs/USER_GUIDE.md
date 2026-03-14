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
4. Enter `Repository`.
5. Refresh or load available source definitions.
6. Install the sources you want to use.

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

- move between pages
- switch chapters with `Prev` and `Next`
- scrub with the progress slider
- open reader settings

If an offline chapter is incomplete or missing, the reader shows an explicit offline error instead of silently switching back to network loading.

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
