# AppleNotesMCP Test Plan

This plan separates safe automated tests from manual or opt-in Apple Notes integration tests.

## Test Principles

- Never mutate personal notes during automated tests.
- Use temporary SQLite databases for automated tests.
- Use `AppleNotesMCP Test` as the only Apple Notes folder for manual integration tests.
- Destructive tests require explicit confirmation.
- Tests must not start daemons, LaunchAgents, HTTP servers, or background polling loops.
- Tests must not call external APIs or the OpenAI API.

## Current Automated Status

Run date: 2026-05-12.

- `swift test` passed with 36/36 harness tests.
- `swift build -c release` passed.
- Automated tests used local Swift logic, temporary SQLite databases, temporary config/log paths, and MCP STDIO smoke coverage.
- Automated tests did not mutate real Apple Notes.

## Automated Tests

### Build

Command:

```sh
swift build -c release
```

Optional helper:

```sh
scripts/build-release.sh
```

Pass criteria:

- Build exits 0.
- Release binary exists at `.build/release/AppleNotesMCP`.

### Local Doctor

Command:

```sh
scripts/doctor.sh
```

Pass criteria:

- Swift is available.
- Apple Notes exists at `/System/Applications/Notes.app`.
- The release binary exists.
- Codex config has a recognizable apple-notes registration hint, or the script reports a warning.
- The minimal `notes_health` MCP smoke test returns a response, unless `--skip-smoke` is used.

### MCP STDIO Smoke

Send:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

Pass criteria:

- Server returns initialize result.
- `tools/list` includes all required tools.
- Process exits when STDIO closes.

### Resource Smoke

Read:

- `notes://health`
- `notes://schema`
- `notes://limitations`
- `notes://config`
- `notes://stats`

Pass criteria:

- All resources return content.
- Health includes database path, default account, indexed count, vector status, schema version, embedding provider/language/dimension, last sync, log level, log path, and limitations.
- Health does not include note body, raw HTML, Markdown body, or attachment content.

### Embedding Provider Resolution

Use only local providers.

Pass criteria:

- `NaturalLanguageEmbeddingProvider` is preferred when the requested language is available.
- Portuguese (`pt`) is the default requested language.
- English (`en`) is tried as the NaturalLanguage fallback.
- If NaturalLanguage is unavailable, `HashingEmbeddingProvider` is selected with warnings.
- `NoopEmbeddingProvider` remains available for disabled embeddings.
- Provider, language, and dimension are reflected in normalized config and health output.

### Safe Observability

Use temporary log files.

Pass criteria:

- Default config keeps `logLevel` as `error`.
- Logger keeps only allowlisted fields: operation, duration, counts, typed error code, truncated note ids, sync/update mode, and provider/dimension/language metadata.
- Logger does not write full note bodies, raw HTML, Markdown body, note titles, search queries, attachment paths, or attachment content.
- Size rotation creates one `.1` backup file.
- Raw `osascript` stderr is classified/redacted before being returned as structured error details.

### Security and Privacy Regression

Use source inspection plus existing safe automated tests.

Pass criteria:

- MCP transport remains STDIO.
- No HTTP server, daemon, LaunchAgent, watcher, polling loop, telemetry, external API call, or OpenAI API call is introduced.
- Apple Notes automation still goes through `/usr/bin/osascript` with JXA.
- JXA scripts accept JSON over stdin and return JSON envelopes.
- The server does not read or write Apple Notes internal databases such as `NoteStore.sqlite`.
- Note content is not placed in shell command arguments.
- Destructive operations require explicit confirmation.
- Attachment paths are expanded and validated before mutation.

### SQLite Migration

Use `APPLE_NOTES_MCP_CONFIG` pointing to a temporary database.

Pass criteria:

- Database file is created.
- WAL mode is active.
- Required tables exist.
- `notes_fts` exists.
- `vec_chunks` exists.
- `vectorSearchAvailable` is true.

### Markdown Conversion

Inputs:

- headings
- bold
- italic
- unordered list
- ordered list
- link
- simple table
- inline code
- code block
- blockquote

Pass criteria:

- Markdown to HTML produces expected tags.
- HTML to Markdown returns readable best-effort content.
- No crash on malformed Markdown/HTML.

### Chunking

Inputs:

- empty note
- short note
- long note over 2,000 tokens

Pass criteria:

- Empty note creates no chunks.
- Short note creates one chunk.
- Long note creates overlapping chunks.
- Chunk indexes are stable and ordered.

### sqlite-vec

Use a temporary SQLite database.

Pass criteria:

- `vec_chunks USING vec0(...)` can be created.
- A vector can be inserted.
- A query vector returns nearest rows.
- Search always uses `LIMIT`.

### FTS5

Insert test notes directly into temporary SQLite through store APIs.

Pass criteria:

- Search finds expected keyword.
- Folder/account filters work.
- Limit is enforced.

### Folder Metadata and Note Search

Use temporary SQLite data only.

Pass criteria:

- Folder summaries include `id`, `path`, `parentId`, `childCount`, and `noteCount`.
- Folder path cache updates preserve notes and update FTS folder metadata.
- Folder cache reconciliation removes stale Apple Notes folder branches without deleting indexed notes.
- `notes_search_notes` filters by `folderPath`, exact `title`, and `titleQuery`.
- Metadata search results do not include note bodies or raw HTML.

### Bulk Operations Dry Run

Use temporary SQLite data only.

Pass criteria:

- `notes_bulk_delete_notes` defaults to `dryRun=true`.
- Dry run reports matched notes without deleting from SQLite or Apple Notes.
- Bulk selection requires `noteIds`, `folderPath`, `title`, or `titleQuery`.

### Hybrid Search

Use controlled fixtures:

- one exact lexical match
- one semantic-only match
- one unrelated note

Pass criteria:

- Exact lexical match ranks high.
- Semantic match appears when vector data exists.
- Results dedupe by note id.
- If vector search is disabled, search returns FTS results with warning.

### Links and Backlinks

Fixtures:

- Source note with `[[Target Note]]`.
- Target note with matching title.

Pass criteria:

- `notes_extract_links` records detected link.
- `notes_backlinks` returns source note.
- Duplicate extraction does not create duplicate detected links.

### Cross-Process Lock

Start two processes using the same temporary config.

Pass criteria:

- One full sync/rebuild can acquire the lock.
- A competing full sync/rebuild returns `sync_already_running`.
- Read/search operations still work while lock is held.

## Manual Apple Notes Integration Tests

Before running:

1. Open Apple Notes manually.
2. Ensure iCloud Notes is available.
3. Create or allow the test folder `AppleNotesMCP Test`.
4. Be ready to approve macOS Automation permission.

### Health and Accounts

Prompt:

```text
Use the apple-notes MCP and call notes_health, then notes_list_accounts.
```

Pass criteria:

- Health status is ok.
- Account list includes `iCloud`.

### Create Folder

Prompt:

```text
Use notes_create_folder with accountName iCloud and folderPath "AppleNotesMCP Test".
```

Pass criteria:

- Folder exists in Apple Notes.
- Calling it again returns success with `existing=true`.

### Folder Management

Use only folders under `AppleNotesMCP Test`.

Prompts:

```text
Use notes_list_folders for accountName iCloud.
```

```text
Use notes_rename_folder to rename "AppleNotesMCP Test/Rename Source" to "Renamed Source".
```

```text
Use notes_move_folder to move "AppleNotesMCP Test/Renamed Source" under "AppleNotesMCP Test/Moved Folders".
```

```text
Use notes_move_folder with folderPath "AppleNotesMCP Test/Moved Folders/Renamed Source" and targetParentFolderPath "" to move it back to the account root.
```

```text
Use notes_delete_folder for "AppleNotesMCP Test/Moved Folders/Renamed Source" with confirm true.
```

Pass criteria:

- `notes_list_folders` returns id/path/parent/count metadata.
- If Apple Notes exposes an inaccessible folder reference, the listing returns remaining folders plus `warnings` instead of failing with `Can't get object`.
- Rename and move are reflected in Apple Notes.
- Delete requires `confirm=true`.
- The local folder cache remains consistent after each mutation.

### Create Note

Prompt:

```text
Use notes_create in "AppleNotesMCP Test" with title "MCP Manual Test" and bodyMarkdown containing a heading, bold text, a bullet list, a numbered list, a link, inline code, a code block, a blockquote, and a [[Target Note]] wikilink.
```

Pass criteria:

- Note appears in Apple Notes.
- Formatting is acceptable.
- Tool returns `indexed=true`.

### Read Note

Prompt:

```text
Use notes_read for title "MCP Manual Test" with includeHTML true and includeMarkdown true.
```

Pass criteria:

- Raw HTML is returned.
- Best-effort Markdown is returned.
- No full content is logged.
- Observed on 2026-05-11: Apple Notes may simplify generated HTML when read back. Ordered lists can return as bullet lists, Markdown links can return as underlined text without the URL, and blockquotes/code blocks can return as simplified text/monospace formatting.

### Update Note

Prompts:

```text
Use notes_update append for title "MCP Manual Test" with bodyMarkdown "Appended line".
```

```text
Use notes_update prepend for title "MCP Manual Test" with bodyMarkdown "Prepended line".
```

```text
Use notes_update replace for title "MCP Manual Test" with confirm false.
```

```text
Use notes_update replace for title "MCP Manual Test" with confirm true and a replacement body.
```

Pass criteria:

- Append/prepend work without confirm.
- Replace with `confirm=false` fails.
- Replace with `confirm=true` works.
- Replace/prepend must preserve the existing note title line. Apple Notes derives the displayed title from the first body line, so update HTML should keep the existing title before inserted/replacement content.

### Sync and Search

Prompts:

```text
Use notes_search_notes with folderPath "AppleNotesMCP Test" and titleQuery "MCP".
```

```text
Use notes_rename_note for title "MCP Manual Test" with newTitle "MCP Manual Test Renamed".
```

```text
Use notes_rename_note for title "MCP Manual Test Renamed" with newTitle "MCP Manual Test".
```

```text
Use notes_sync_index with mode incremental, includeEmbeddings true, maxNotes 20.
```

```text
Use notes_search_fts with query "MCP" and limit 5.
```

```text
Use notes_search_rag with query "manual test note" and limit 5.
```

```text
Use notes_search_hybrid with query "manual test note" and limit 5.
```

Pass criteria:

- Metadata search finds the test note without returning body content.
- Rename updates the visible Apple Notes title, preserves body content, and can rename the note back for later steps.
- Sync indexes changed notes.
- FTS finds the test note.
- RAG returns a result or a clear typed error.
- Hybrid returns results and no silent fallback.

### Bulk Move, Archive, Delete Dry Run

Use only notes created in `AppleNotesMCP Test`.

Prompts:

```text
Use notes_bulk_move_notes with folderPath "AppleNotesMCP Test" and titleQuery "MCP Manual Test" to targetFolderPath "AppleNotesMCP Test/Bulk Moved".
```

```text
Use notes_bulk_archive_notes with folderPath "AppleNotesMCP Test/Bulk Moved" and titleQuery "MCP Manual Test" and archiveFolderPath "AppleNotesMCP Test/Archive".
```

```text
Use notes_bulk_delete_notes with folderPath "AppleNotesMCP Test/Archive", titleQuery "MCP Manual Test", and dryRun true.
```

Pass criteria:

- Bulk move and archive affect only matched test notes.
- Bulk delete dry run reports matches and deletes nothing.
- Running bulk delete with `dryRun=false` requires `confirm=true`.

### Attach File

Create a small text file under `/private/tmp`.

Prompt:

```text
Use notes_attach_file for title "MCP Manual Test" with filePath "/private/tmp/example.txt" and mode "real_attachment_preferred".
```

Pass criteria:

- Tool validates the file.
- If real attachment is unreliable, the note gets a `file://` link.
- SQLite attachment metadata is recorded.
- Result includes `attachedAs`.
- Observed on 2026-05-11: `real_attachment_preferred` returned `attachedAs: file_link_fallback` with an explicit warning.

### Links and Backlinks

Prompts:

```text
Create a note titled "Target Note" in "AppleNotesMCP Test".
```

```text
Use notes_link from "MCP Manual Test" to "Target Note" with mode "wikilink".
```

```text
Use notes_extract_links on "MCP Manual Test".
```

```text
Use notes_backlinks on "Target Note".
```

Pass criteria:

- Wikilink is added without corrupting body.
- Extracted links are stored.
- Backlinks show the source note.

### Move

Prompt:

```text
Use notes_move for title "MCP Manual Test" to targetFolderPath "AppleNotesMCP Test/Moved" with createFolderIfMissing true.
```

Pass criteria:

- Target folder is created if supported.
- Note moves or returns a typed, documented automation limitation.

### Delete

Prompt:

```text
Use notes_delete for title "MCP Manual Test" with confirm false.
```

Then:

```text
Use notes_delete for title "MCP Manual Test" with confirm true.
```

Pass criteria:

- `confirm=false` fails.
- `confirm=true` deletes in Notes or marks deleted if automation limitation is encountered.

## Manual Apple Notes Validation Results

Run date: 2026-05-11.

Validated successfully in the dedicated iCloud folder `AppleNotesMCP Test`:

- `notes_health`
- `notes_list_accounts`
- `notes_create_folder` creation and idempotent `existing=true`
- `notes_create`
- `notes_read` with HTML and Markdown
- `notes_update` append, prepend, replace refusal with `confirm=false`, and replace with `confirm=true`
- `notes_link`, `notes_extract_links`, and `notes_backlinks`
- `notes_sync_index` incremental with local embeddings
- `notes_search_fts`, `notes_search_rag`, and `notes_search_hybrid`
- `notes_attach_file` with explicit file-link fallback
- `notes_move` to `AppleNotesMCP Test/Moved`
- `notes_delete` refusal with `confirm=false` and deletion with `confirm=true`

Observed limitations:

- Apple Notes simplified some rich formatting on read-back: ordered lists returned as bullet lists, links returned without href, and blockquotes/code blocks returned as best-effort text/monospace formatting.
- Apple Notes exposed a stale or inaccessible `20 Projetos` folder reference during later folder enumeration; after the stale branch was removed in Apple Notes, `notes_list_folders` returned without warnings. The server now reconciles the local folder cache from reachable live folders when list enumeration completes.
- A replace body whose first line was a heading changed the displayed Apple Notes title before the server-side fix. The update path now composes HTML with the existing title line first and indexes the actual JXA response.
- Sending multiple `tools/call` requests without waiting for prior responses can execute them out of order; manual validation steps should wait for each mutating result before sending the next dependent request.
