# AppleNotesMCP

AppleNotesMCP is a local-first MCP STDIO server for macOS that lets Codex CLI work with the native Apple Notes app.

It uses supported macOS automation paths (`osascript` with JXA) and never writes to Apple Notes internal databases such as `NoteStore.sqlite`. The project SQLite database is only a cache, search index, link graph, attachment metadata store, and embedding cache.

## Requirements

- macOS with Apple Notes installed at `/System/Applications/Notes.app`
- Swift 6.3.1
- Swift Package Manager
- Codex CLI
- SQLite with FTS5, available through the macOS system SQLite
- Embedded `sqlite-vec v0.1.9`

No external service, OpenAI API key, daemon, LaunchAgent, HTTP server, watcher, or polling process is required.

## Setup

1. Build the release binary:

```sh
swift build -c release
```

2. Configure Codex with the absolute binary path shown below.

3. Restart Codex and run `/mcp`.

4. On the first real Apple Notes operation, approve the macOS Automation prompt if one appears.

5. Run `notes_health`, then `notes_list_accounts`, and then `notes_sync_index` when you want to populate or refresh the local search index.

## Build

```sh
swift build -c release
```

Or use the helper:

```sh
scripts/build-release.sh
```

The release binary is created at:

```text
.build/release/AppleNotesMCP
```

## Codex CLI Configuration

Use an absolute path in `~/.codex/config.toml`:

```toml
[mcp_servers.apple-notes]
command = "/ABSOLUTE/PATH/TO/AppleNotesMCP/.build/release/AppleNotesMCP"
args = []
enabled = true
startup_timeout_sec = 10
tool_timeout_sec = 60
```

Or register it with the CLI:

```sh
codex mcp add apple-notes -- /ABSOLUTE/PATH/TO/AppleNotesMCP/.build/release/AppleNotesMCP
```

Restart Codex, then run:

```text
/mcp
```

You should see `apple-notes` and the tools exposed by this server.

To run local setup checks:

```sh
scripts/doctor.sh
```

Use `scripts/doctor.sh --skip-smoke` to skip the `notes_health` smoke test.

## Runtime Model

- Codex starts the server automatically for each Codex session.
- Transport is MCP STDIO only.
- The server stays alive while the corresponding STDIO session is alive.
- The server exits when STDIO closes.
- No daemon is installed.
- No LaunchAgent is required in the default setup.
- No HTTP server is started.
- Multiple Codex terminals may start multiple AppleNotesMCP processes.

SQLite is configured with:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
```

Full sync and rebuild operations use a lightweight cross-process file lock. Normal reads and searches do not use that lock.

`sqlite-vec v0.1.9` is vendored from the official release amalgamation and compiled into the binary. The release archive used was:

```text
https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-amalgamation.tar.gz
```

Local SHA256:

```text
3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61
```

Swift package dependencies are pinned: `Package.swift` requires `modelcontextprotocol/swift-sdk` exactly at `0.12.1`, and `Package.resolved` records the exact transitive package revisions used by SwiftPM.

## Default Configuration

Effective defaults after config normalization on this Mac:

```json
{
  "defaultAccount": "iCloud",
  "allowOnMyMac": true,
  "databasePath": "~/Library/Application Support/AppleNotesMCP/index.sqlite",
  "logPath": "~/Library/Logs/AppleNotesMCP/server.log",
  "logLevel": "error",
  "embeddingsEnabled": true,
  "maxEmbeddingConcurrency": 1,
  "maxSyncConcurrency": 1,
  "syncLockPath": "~/Library/Application Support/AppleNotesMCP/sync.lock",
  "embeddingProvider": "NaturalLanguageEmbeddingProvider",
  "embeddingLanguage": "pt",
  "embeddingDimension": 640
}
```

Optional config file:

```text
~/Library/Application Support/AppleNotesMCP/config.json
```

Or set:

```sh
APPLE_NOTES_MCP_CONFIG=/path/to/config.json
```

`embeddingDimension` is resolved at startup from the active provider and language. On this Mac, Apple NaturalLanguage Portuguese sentence embeddings resolve to 640 dimensions. If Portuguese is unavailable, the server tries English. If no Apple NaturalLanguage sentence embedding is available, it falls back to `HashingEmbeddingProvider` with an explicit warning in health/config output.

The raw fallback dimension for `HashingEmbeddingProvider` is 384 unless the config file sets another dimension.

## macOS Permissions

The first Apple Notes automation call may trigger a macOS permission prompt allowing the terminal/Codex process to control Notes.

If calls fail with `apple_notes_permission_denied`, check:

```text
System Settings -> Privacy & Security -> Automation
```

Allow the terminal app that launches Codex to control Notes.

## Tools

Detailed tool documentation is available in [TOOLS.md](TOOLS.md).

Implemented MCP tools:

- `notes_health`
- `notes_list_accounts`
- `notes_list_folders`
- `notes_create_folder`
- `notes_rename_folder`
- `notes_move_folder`
- `notes_delete_folder`
- `notes_create`
- `notes_read`
- `notes_update`
- `notes_rename_note`
- `notes_delete`
- `notes_move`
- `notes_search_notes`
- `notes_search_fts`
- `notes_search_rag`
- `notes_search_hybrid`
- `notes_sync_index`
- `notes_rebuild_search`
- `notes_attach_file`
- `notes_bulk_move_notes`
- `notes_bulk_archive_notes`
- `notes_bulk_delete_notes`
- `notes_merge_folders`
- `notes_link`
- `notes_backlinks`
- `notes_extract_links`

## Folder and Bulk Operations

`notes_list_folders` returns folder metadata from Apple Notes plus local cache ids: `id`, `accountName`, `path`, `parentId`, `childCount`, and `noteCount`.

If Apple Notes exposes an inaccessible folder reference during enumeration, the server skips that reference and returns a `warnings` array instead of failing the whole listing with a generic automation error. After a successful live enumeration, the local folder cache is reconciled to the reachable Apple Notes folders without deleting notes from the local note index.

Folder mutations use Apple Notes automation and then update the local SQLite cache:

- `notes_rename_folder`
- `notes_move_folder`; pass `targetParentFolderPath` as an empty string (`""`) to move a folder to the root of the target account
- `notes_delete_folder` with `confirm=true`
- `notes_merge_folders` to move direct notes from a source folder to a target folder, then delete the empty source folder

Bulk note operations select notes from the local SQLite index by `noteIds`, `folderPath`, `title`, or `titleQuery`:

- `notes_search_notes`
- `notes_bulk_move_notes`
- `notes_bulk_archive_notes`
- `notes_bulk_delete_notes`, defaulting to `dryRun=true`
- `notes_rename_note`

Run `notes_sync_index` first if the local index may be stale.

## Sync

Full sync is manual and explicit:

```json
{
  "mode": "full",
  "includeEmbeddings": true
}
```

Incremental sync is the normal path:

```json
{
  "mode": "incremental",
  "includeEmbeddings": true
}
```

The server compares Apple note id, title, folder, update metadata when available, and a body hash. It indexes only changed notes during incremental sync.

Full sync marks locally indexed notes as deleted when they are missing from the Apple Notes listing for the selected scope. Incremental sync does not mark missing notes deleted.

`notes_rebuild_search` rebuilds FTS and/or vector chunks from the local SQLite cache and uses the same cross-process lock as full sync.

If another full sync or rebuild is active, the server returns:

```json
{
  "code": "sync_already_running"
}
```

## Search

Metadata search by title and folder:

```json
{
  "folderPath": "Projects",
  "titleQuery": "plan",
  "limit": 10
}
```

FTS5 keyword search:

```json
{
  "query": "project plan",
  "limit": 10
}
```

RAG search:

```json
{
  "query": "project risks",
  "limit": 10
}
```

Hybrid search:

```json
{
  "query": "project risks",
  "limit": 10,
  "lexicalWeight": 0.65,
  "vectorWeight": 0.35
}
```

Embeddings are local by default. The preferred provider is `NaturalLanguageEmbeddingProvider`, using Apple NaturalLanguage sentence embeddings with no external API, OpenAI API, or model download. `HashingEmbeddingProvider` remains as a safe local fallback and vectors are stored in the embedded sqlite-vec `vec0` table. If vector indexing fails, hybrid search returns a warning and falls back to FTS5.

`notes_search_rag` returns chunk-level metadata when available: `noteId`, `title`, short `snippet`, `accountName`, `folderPath`, `vectorScore`, and `chunkIndex`.

Search `limit` values are bounded to 1 through 50. `notes_search_hybrid` fetches FTS5 and sqlite-vec candidates with `candidateLimit = max(limit * 5, 30)`, normalizes lexical and vector scores separately, deduplicates by `noteId`, and returns `lexicalScore`, `vectorScore`, `combinedScore`, and `rankReason`. When combined scores are close, stronger lexical matches sort first.

## Attachments

`notes_attach_file` expands `~`, requires an absolute path, resolves symlinks, and validates that `filePath` is an existing readable regular file. Relative paths, directories, and special files are rejected before any Apple Notes update is attempted.

Real Apple Notes attachments are not reliable through scripting automation on all systems. When real attachment is not reliable, the server appends a `file://` link to the note and records attachment metadata in SQLite. It returns `attachedAs: file_link_fallback` and a warning instead of failing silently.

The `copyToManagedFolder` argument is accepted by the tool schema but the current implementation does not copy files into a managed storage folder. The validated source file is linked directly with a `file://` URL.

## Markdown and HTML

Create and update operations convert Markdown to HTML before sending content to Apple Notes.

Supported best-effort formatting:

- headings
- bold
- italic
- bullet lists
- numbered lists
- links
- simple tables
- inline code
- code blocks
- blockquotes
- wikilinks like `[[Note Title]]`

Reads return raw HTML and best-effort Markdown.

Manual validation on macOS on 2026-05-11 showed that Apple Notes accepts the generated HTML but may simplify it when read back through automation: ordered lists can return as bullet lists, links can return as underlined text without the URL, and blockquotes/code blocks can return as plain or monospace text rather than exact Markdown structure.

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

## Project Documentation

Supporting docs:

- `TOOLS.md`: MCP tools, arguments, safety gates, resources, prompts, and Apple Notes automation limits.
- `docs/FINALIZATION_REVIEW.md`: current finalization status, completed phases, limitations, and remaining optional work.
- `docs/TEST_PLAN.md`: safe automated tests and manual Apple Notes integration runbook.

## Logs

Default log path:

```text
~/Library/Logs/AppleNotesMCP/server.log
```

Default level is `error`.

The server does not log complete note bodies, complete Markdown, complete HTML, raw automation HTML, attachment content, note titles, search queries, prompt arguments, or attachment paths. Logs are allowlisted to operation, duration, counts, typed error code, sync/update mode, provider/dimension/language metadata, and truncated note ids. Raw `osascript` stderr is classified/redacted before being returned in structured errors. A simple size-based rotation keeps one `.1` file.

## Security and Privacy

- Local-first
- No telemetry
- No external API calls by default
- No OpenAI API calls by default
- No HTTP port
- No daemon by default
- No LaunchAgent by default
- Does not read or write Apple Notes internal databases
- Uses Apple Notes automation through `osascript`
- Sends JXA input as JSON over stdin and expects structured JSON envelopes in response
- Does not place note content in shell command arguments
- Validates attachment paths before linking
- Rejects destructive delete/merge operations unless `confirm=true`; bulk delete defaults to `dryRun=true`
- `notes_health` exposes status, config paths, counts, embedding metadata, permissions, and limitations, but not note bodies, note titles, search queries, attachment contents, or prompt arguments
- `notes_list_folders` exposes folder id/account/path/parent/count metadata only; it does not return note bodies or attachment contents
- Does not execute shell commands from note content

## Automated and Manual Tests

Automated checks:

```sh
swift test
swift build -c release
```

`swift test` runs a local harness against pure Swift logic, temporary SQLite databases, temporary config/log paths, and an MCP STDIO smoke test. It does not mutate real Apple Notes.

Manual Apple Notes validation is documented in `docs/TEST_PLAN.md` and must use only the dedicated `AppleNotesMCP Test` folder unless the user explicitly requests otherwise. Mutating manual steps should wait for each tool result before sending the next dependent request.

## Known Limitations

- Apple Notes automation may not expose 100% of UI behavior.
- Apple Notes can expose stale or inaccessible folder references after folder moves/deletes; `notes_list_folders` skips them with warnings and reconciles the local folder cache from reachable folders. If a warning persists for the same branch, repair or remove that branch in Apple Notes.
- Rich formatting is best effort.
- Markdown round-trip through Apple Notes may simplify ordered lists, links, blockquotes, and code blocks.
- Apple Notes derives the displayed note title from the first body line; update operations preserve the existing title line before replacing/prepending content.
- Native checklist state may not round-trip perfectly.
- Real attachments may fall back to `file://` links.
- `copyToManagedFolder` is not implemented; attachments currently link the validated source file directly.
- iCloud sync depends on Apple Notes and iCloud, not this MCP server.
- HTML to Markdown conversion is best effort.
- Vector search depends on indexed chunks with fresh embeddings; hybrid search falls back to FTS5 with a warning if sqlite-vec search is unavailable.

## Troubleshooting

Run the local doctor:

```sh
scripts/doctor.sh
```

It checks Swift, the release binary, Codex config hints, Apple Notes app presence, and a minimal `notes_health` MCP smoke test.

Build fails with toolchain errors:

- Verify `swift --version` reports Swift 6.3.1.
- Ensure Command Line Tools/Xcode match the installed SDK.

Codex does not show the server:

- Rebuild with `swift build -c release`.
- Verify the absolute path in `~/.codex/config.toml`.
- Restart Codex.
- Check `/mcp`.

Apple Notes calls fail:

- Open Apple Notes once manually.
- Check macOS Automation permissions.
- Run `notes_health` and inspect `permissions`.

Search returns no results:

- Run `notes_sync_index` with `mode: "incremental"` or `mode: "full"`.
- Use `notes_search_fts` first.

Hybrid search warns about vector search:

- Run `notes_sync_index` or `notes_rebuild_search` with embeddings enabled.
- If vector data is stale or unavailable, the server falls back safely and FTS5 search remains available.
