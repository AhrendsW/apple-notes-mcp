# AppleNotesMCP Tools

This document lists the MCP tools exposed by AppleNotesMCP and the important operational limits for each group.

The server is local-first, uses MCP over STDIO, and talks to Apple Notes only through supported macOS automation with JXA via `/usr/bin/osascript`. It does not read or write Apple Notes internal databases.

## General Rules

- Prefer `noteId` over `title` when a title may be duplicated.
- Run `notes_sync_index` before search tools if the SQLite index may be stale.
- Mutating Apple Notes tools may trigger macOS Automation permission prompts.
- Destructive tools require explicit confirmation.
- Bulk delete defaults to dry run.
- Search tools read from the local SQLite index, not directly from Apple Notes.
- Logs are content-safe by design and should not contain note bodies, raw HTML, Markdown bodies, note titles, search queries, attachment paths, or attachment content.

## Health and Discovery

### `notes_health`

Returns server status, config paths, counts, schema version, embedding metadata, vector availability, last sync, macOS automation permission status, and known limitations.

Arguments: none.

Notes:

- Calls Apple Notes automation to determine permission status.
- Does not return note bodies or attachment content.

### `notes_list_accounts`

Lists Apple Notes accounts.

Arguments: none.

### `notes_list_folders`

Lists Apple Notes folders and merges live Apple Notes metadata with local cache ids and counts.

Arguments:

- `accountName`: optional Apple Notes account name.

Returns:

- `folders`: folder metadata with `id`, `accountName`, `path`, `parentId`, `childCount`, and `noteCount`.
- `warnings`: optional warnings when Apple Notes exposes an inaccessible folder reference.

Notes:

- Inaccessible folder references are skipped instead of failing the entire listing.
- After a successful live enumeration, the local folder cache is reconciled to the reachable Apple Notes folders without deleting notes from the local note index.
- Folder names and paths are returned by design because this is a folder listing tool.

## Folder Tools

### `notes_create_folder`

Creates a folder idempotently.

Arguments:

- `accountName`: optional account name, defaults to config `defaultAccount`.
- `folderPath`: required folder path.

Notes:

- Existing folders return success with `existing=true`.

### `notes_rename_folder`

Renames an Apple Notes folder.

Arguments:

- `accountName`: optional account name.
- `folderPath`: required current folder path.
- `newName`: required new folder name, not a path.

### `notes_move_folder`

Moves a folder under another parent folder, optionally renaming it.

Arguments:

- `accountName`: optional source account name.
- `folderPath`: required source folder path.
- `targetAccountName`: optional target account name.
- `targetParentFolderPath`: required target parent folder path.
- `newName`: optional new folder name.
- `createFolderIfMissing`: optional, defaults to `true`.

Notes:

- Refuses moving a folder into itself or a child path.
- Use `targetParentFolderPath: ""` to move the folder to the root of the target account.

### `notes_delete_folder`

Deletes an Apple Notes folder and marks indexed notes under that path as deleted.

Arguments:

- `accountName`: optional account name.
- `folderPath`: required folder path.
- `confirm`: required for deletion; must be `true`.

## Note Tools

### `notes_create`

Creates a note in Apple Notes from Markdown and indexes it locally.

Arguments:

- `accountName`: optional account name.
- `folderPath`: optional folder path.
- `title`: required title.
- `bodyMarkdown`: required Markdown body.
- `tags`: optional string array stored in SQLite metadata.
- `experimentalNativeUI`: optional boolean. When `true`, attempts to append `tags` as native Apple Notes tags through visual UI automation after creating the note.
- `preserveFormatting`: optional, currently accepted by schema.

### `notes_read`

Reads a note by `noteId` or exact `title`.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `includeHTML`: optional, defaults to `true`.
- `includeMarkdown`: optional, defaults to `true`.

Notes:

- If an Apple note id exists, the tool tries to refresh content from Apple Notes.
- If Apple Notes read fails, it can return cached SQLite content with a warning.

### `notes_update`

Updates a note by replacing, appending, or prepending Markdown.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `bodyMarkdown`: required Markdown body.
- `mode`: required, one of `replace`, `append`, or `prepend`.
- `preserveFormatting`: optional, defaults to `true`.
- `confirm`: required only for `replace`; must be `true`.

Notes:

- The update path preserves the Apple Notes title line because Notes derives the displayed title from the first body line.

### `notes_rename_note`

Renames a note while preserving the Apple Notes title line in the note body.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `newTitle`: required new title.

### `notes_delete`

Deletes a note in Apple Notes and marks it deleted in SQLite.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `confirm`: required for deletion; must be `true`.

### `notes_move`

Moves a note to another Apple Notes folder.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `targetAccountName`: optional target account name.
- `targetFolderPath`: required target folder path.
- `createFolderIfMissing`: optional, defaults to `true`.

## Search Tools

### `notes_search_notes`

Searches indexed note metadata only.

Arguments:

- `noteIds`: optional string array.
- `accountName`: optional account filter.
- `folderPath`: optional folder filter.
- `title`: optional exact title filter.
- `titleQuery`: optional title substring filter.
- `limit`: optional, defaults to `100`.

Notes:

- Does not return note bodies or raw HTML.

### `notes_search_fts`

Searches indexed notes with SQLite FTS5.

Arguments:

- `query`: required FTS query.
- `limit`: optional, defaults to `10`.
- `accountName`: optional account filter.
- `folderPath`: optional folder filter.

### `notes_search_rag`

Searches indexed chunks with local embeddings through embedded sqlite-vec.

Arguments:

- `query`: required natural-language query.
- `limit`: optional, defaults to `10`.
- `accountName`: optional account filter.
- `folderPath`: optional folder filter.

Notes:

- Uses local embeddings only.
- No external API or OpenAI API is called.

### `notes_search_hybrid`

Combines FTS5 and sqlite-vec candidates.

Arguments:

- `query`: required query.
- `limit`: optional, defaults to `10`.
- `lexicalWeight`: optional, defaults to `0.65`.
- `vectorWeight`: optional, defaults to `0.35`.
- `accountName`: optional account filter.
- `folderPath`: optional folder filter.

Returns score components:

- `lexicalScore`
- `vectorScore`
- `combinedScore`
- `rankReason`

Notes:

- Fetches lexical and vector candidates, normalizes scores independently, dedupes by note id, and prefers stronger lexical matches when scores are close.
- Falls back to FTS5 with a warning if vector search is unavailable.

## Sync and Rebuild

### `notes_sync_index`

Runs manual incremental or full sync from Apple Notes into SQLite.

Arguments:

- `mode`: required, `incremental` or `full`.
- `accountName`: optional account scope.
- `folderPath`: optional folder scope.
- `includeEmbeddings`: optional, defaults to `true`.
- `maxNotes`: optional cap for listing/indexing.

Notes:

- Incremental sync indexes changed notes only.
- Full sync marks missing notes as deleted within the selected scope.
- Full sync uses a cross-process lock and returns `sync_already_running` if another full sync or rebuild is active.
- Normal reads and searches continue working while another process syncs.

### `notes_rebuild_search`

Rebuilds FTS and/or vector chunks from the existing SQLite note cache.

Arguments:

- `rebuildFTS`: optional, defaults to `true`.
- `rebuildVectors`: optional, defaults to `true`.

Notes:

- Uses the same cross-process lock as full sync.
- Does not fetch Apple Notes content; run `notes_sync_index` first if the cache may be stale.

## Attachments

### `notes_attach_file`

Attaches by real attachment when reliable, otherwise appends a `file://` link fallback and records attachment metadata in SQLite.

Arguments:

- `noteId`: optional local note id.
- `title`: optional exact title.
- `filePath`: required absolute readable regular file path.
- `mode`: required, `real_attachment_preferred` or `file_link_only`.
- `copyToManagedFolder`: optional, accepted by schema but not implemented as a file copy.

Notes:

- Expands `~`, requires an absolute path, resolves symlinks, and rejects directories and special files.
- Current implementation links the validated source file directly with `file://`.
- Real Apple Notes attachments are not reliable through scripting automation, so `file_link_fallback` is expected on systems where native insertion is unavailable.

## Bulk Note Tools

Bulk tools select indexed notes by `noteIds`, `folderPath`, `title`, or `titleQuery`. Run `notes_sync_index` first if the local index may be stale.

### `notes_bulk_move_notes`

Moves selected indexed notes to a target folder.

Arguments:

- `noteIds`: optional string array.
- `accountName`: optional source account filter.
- `folderPath`: optional source folder filter.
- `title`: optional exact title filter.
- `titleQuery`: optional title substring filter.
- `limit`: optional, defaults to `100`.
- `targetAccountName`: optional target account name.
- `targetFolderPath`: required target folder path.
- `createFolderIfMissing`: optional, defaults to `true`.

### `notes_bulk_archive_notes`

Moves selected notes to an archive folder.

Arguments:

- Same selection arguments as `notes_bulk_move_notes`.
- `targetAccountName`: optional target account name.
- `archiveFolderPath`: optional, defaults to `Archive`.
- `createFolderIfMissing`: optional, defaults to `true`.

### `notes_bulk_delete_notes`

Deletes selected notes, defaulting to dry run.

Arguments:

- Same selection arguments as `notes_bulk_move_notes`.
- `dryRun`: optional, defaults to `true`.
- `confirm`: required only when `dryRun=false`; must be `true`.

### `notes_merge_folders`

Moves direct notes from a source folder to a target folder, then deletes the empty source folder.

Arguments:

- `accountName`: optional account name.
- `sourceFolderPath`: required source folder path.
- `targetFolderPath`: required target folder path.
- `confirm`: required; must be `true`.
- `limit`: optional, defaults to `100`.

Notes:

- Refuses to merge a source folder that still has child folders.

## Links and Backlinks

### `notes_link`

Creates a wikilink or related section and registers the link in SQLite.

Arguments:

- `sourceNoteId`: optional source note id.
- `sourceTitle`: optional source title.
- `targetNoteId`: optional target note id.
- `targetTitle`: optional target title.
- `linkText`: optional displayed link text.
- `mode`: required, `wikilink` or `related_section`.
- `experimentalNativeUI`: optional boolean. When `true`, attempts to create a native Apple Notes note-to-note link through visual UI automation instead of writing a Markdown `[[wikilink]]`.

Experimental native UI mode requires `linkText` to match the target note title. Apple Notes' `>>` shortcut uses the target title as the link text.

If visual automation fails, the tool records the relationship in the SQLite link index and returns `nativeApplied=false`, `fallback=sqlite_link_index`, and a concise `limitation` explaining that Apple Notes native tags and note links are not reliably writable through supported automation.

### `notes_apply_native_tags`

Experimentally appends native Apple Notes tags through visual UI automation.

Arguments:

- `noteId`: optional note id.
- `title`: optional exact title.
- `tags`: required string array. Tags must be single words using letters, numbers, hyphens, or underscores.
- `experimentalNativeUI`: required boolean and must be `true`.

This tool is intentionally opt-in. It uses Notes plus System Events to focus the note and type `#tag ` text so Apple Notes may convert it to native tags.

If visual automation fails, the tool still stores the tags in SQLite metadata and returns `nativeApplied=false`, `fallback=sqlite_metadata`, and a concise `limitation` explaining that Apple Notes native tags and note links are not reliably writable through supported automation. It may also return a coarse safe `reason` such as `accessibility_or_automation_permission_denied`, `note_object_or_ui_element_unavailable`, or `redacted_ui_automation_error`. It does not return raw UI automation errors because they can contain local UI state.

### `notes_backlinks`

Returns notes that link to a target note.

Arguments:

- `noteId`: optional target note id.
- `title`: optional target title.

### `notes_extract_links`

Extracts `[[wikilinks]]` from a note and updates detected links in SQLite.

Arguments:

- `noteId`: optional source note id.
- `title`: optional source title.

## Resources

Implemented MCP resources:

- `notes://health`
- `notes://schema`
- `notes://limitations`
- `notes://config`
- `notes://stats`

## Prompts

Implemented MCP prompts:

- `create_meeting_note`
- `create_technical_note`
- `create_daily_log`

## Known Apple Notes Automation Limits

- Apple Notes automation may simplify rich formatting on read-back.
- Native Apple Notes tags and native note-to-note links are not exposed through the stable Notes automation dictionary. Experimental native UI tools simulate visible app interaction through System Events and require `experimentalNativeUI=true`.
- Experimental native UI automation can fail if Accessibility/Automation permissions are missing, Notes focus changes, the wrong note is selected, note titles are duplicated, iCloud sync is delayed, the keyboard layout or app language differs, the user interacts with mouse/keyboard during the run, or macOS changes Notes UI behavior. A failed run may partially type into the visible note.
- When experimental native UI automation fails, tag and link tools fall back to MCP-owned SQLite metadata/link records where possible and report `nativeApplied=false`.
- Note update/write paths avoid reading the full note body back immediately after mutation because Apple Notes can invalidate note object references and raise `Can't get object`.
- Apple Notes can expose stale or inaccessible folder references after folder moves/deletes; `notes_list_folders` skips them with warnings and reconciles the local folder cache from reachable folders. If a warning persists for the same branch, repair or remove that branch in Apple Notes.
- Note moves can fail when Apple Notes exposes stale note or folder object references. The implementation resolves the target folder before moving, avoids post-move body read-back, and falls back to title/account/folder matching when the cached Apple note id is not enough.
- Ordered lists, links, blockquotes, and code blocks may not round-trip exactly.
- Native checklist state may not round-trip perfectly.
- Real attachments may fall back to `file://` links.
- iCloud sync timing is controlled by Apple Notes and iCloud, not this server.
