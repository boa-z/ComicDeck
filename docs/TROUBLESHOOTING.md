# Troubleshooting

## Before You Start

When something looks wrong, collect the failure context first.

1. Reproduce the issue again after a fresh app launch.
2. Open `Settings -> Debug Logs`.
3. Record the visible error message, source key, and exact screen/action path.

For network-related problems, do not rely on system `nw_connection...` messages alone. They are often transport noise rather than the application failure.

## Source Issues

### A Source Installs but Cannot Browse or Search

Check:

1. the source is selected as active
2. repository refresh succeeded
3. the source is not outdated and has no pending update

If the problem remains:

1. open `Debug Logs`
2. filter to `Warn+Error`
3. review `SourceRuntime` and `JS` log lines

Typical causes:

- source script incompatibility
- upstream API changes
- missing login or expired session state

### Login Fails for a Source

Verify the expected login mode first:

- account login
- web login
- cookie login

Then confirm:

1. the source detail page exposes that login capability
2. the session state refreshed after login

If it still fails, capture:

- request and response log lines
- source key
- failing endpoint if visible

## Reader Issues

### Resume Opens the Wrong Place

ComicDeck prefers chapter-aware resume. If a history record is too old to map safely to a concrete chapter, the app falls back to the comic detail page intentionally.

This is expected for stale history data.

### Offline Read Reports Missing Files

Common causes:

1. the offline chapter is incomplete
2. local files were removed manually
3. offline index data is stale

Fix path:

1. open `Library -> Downloads`
2. switch to `Offline`
3. run `Reindex`
4. if still incomplete, remove the chapter and download it again

## Download Issues

### A Completed Item Still Appears in Queue

Expected queue states are:

- queued
- downloading
- failed

Completed chapters should appear in `Offline`, not stay in `Queue`.

Fix path:

1. open `Library -> Downloads`
2. switch to `Offline`
3. run `Reindex`

If the inconsistency remains, capture debug logs around download completion and include both queue and offline behavior in the report.

### Download Progress Does Not Update Visibly

Check:

1. the item is in `Queue`, not `Offline`
2. the source is actually serving page images

If `Live Activity` progresses but the queue UI does not, collect download logs from `Debug Logs` and include the source key and chapter.

### Offline Chapter Shows as Incomplete

This usually means the number of local image files does not match the expected chapter page set.

Fix path:

1. reindex the offline library
2. delete the incomplete chapter
3. download it again

## Backup and Restore

### Restore Succeeds but Downloads Are Missing

This is expected. Backups do not include:

- offline chapter files
- active download queue

Only library data and settings are restored.

### Restored Data Looks Outdated

Possible causes:

1. the selected backup file was not the newest one
2. the latest remote backup was overwritten earlier than expected

Fix path:

1. open `WebDAV Sync`
2. refresh remote backups
3. restore the newest timestamped snapshot explicitly

## WebDAV Issues

### Test Connection Fails

Check:

1. the directory URL points to a WebDAV directory, not a file
2. username and password are correct
3. the server accepts basic auth and required WebDAV methods

ComicDeck relies on:

- `PROPFIND`
- `PUT`
- `GET`
- `DELETE`
- `MKCOL`

If the server blocks one of these methods, sync will fail.

### Remote Backups Do Not Appear

Check:

1. the directory URL is correct
2. the directory actually contains `.json` backups
3. `Refresh Remote Backups` succeeds

ComicDeck intentionally filters remote entries to JSON backup files.

### Restore Latest Remote Backup Fails

Likely causes:

1. there are no remote JSON backups
2. the newest backup file is malformed
3. credentials work for listing but fail for download

## UI and Navigation Issues

### Back from Reader Lands in the Wrong Place

Intended behavior:

- resume from history re-enters through detail, then opens reader
- back from reader returns to detail, not directly to the history list

If behavior differs, record:

1. where resume was launched from
2. what path the back button actually took

### Selection Mode Feels Inconsistent

Current design uses:

- tap-based selection
- batch action bars

When reporting an issue, include:

- page name
- list or grid mode
- whether batch actions were visible

## Debug Logs

Use `Settings -> Debug Logs` for:

- source runtime errors
- login failures
- WebDAV failures
- download state anomalies

When sharing logs:

1. prefer `Warn+Error`
2. include the action path that produced the issue
3. include the source key and comic/chapter if available
