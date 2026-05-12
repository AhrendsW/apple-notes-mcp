# AppleNotesMCP Finalization Review

Date: 2026-05-11

Updated: 2026-05-12

This document reviews what remains to turn the current functional MVP into a polished, low-impact final version and records completed finalization decisions.

## Current Verified State

- `swift test` succeeds with the local harness. On 2026-05-12 it reported 36/36 passing after Phase 10 acceptance fixes.
- `swift build -c release` succeeds. On 2026-05-12 it completed successfully.
- Codex `/mcp` shows `apple-notes` and all required tools.
- The user confirmed real Apple Notes folder and note creation worked through Codex.
- `notes_health` reported `apple_notes_automation_available`.
- `sqlite-vec v0.1.9` is vendored and embedded; `notes_health` reported `vectorSearchAvailable: true`.
- Current SQLite schema version is 2.
- The server is MCP STDIO only, with no daemon, no LaunchAgent, and no HTTP server.
- SQLite uses WAL, short transactions, and a file lock only for expensive full sync/rebuild operations.
- Default embeddings are local Apple NaturalLanguage sentence embeddings when available, configured as `NaturalLanguageEmbeddingProvider` with language `pt`; the code falls back to English and then `HashingEmbeddingProvider` with warnings if needed.
- Phase 5 manual validation on 2026-05-11 used only the `AppleNotesMCP Test` folder in the iCloud account.
- Phase 6 safe observability is implemented and covered by automated tests.
- Folder/note management tools were added after Phase 6: `notes_rename_folder`, `notes_move_folder`, `notes_delete_folder`, `notes_search_notes`, `notes_rename_note`, `notes_bulk_move_notes`, `notes_bulk_archive_notes`, `notes_bulk_delete_notes`, and `notes_merge_folders`.
- Phase 7 security review is implemented and covered by automated tests for safe logging, health output, attachment path validation, destructive confirmation gates, and automation stderr redaction.
- Phase 8 documentation finalization is complete in README, this review, and the test plan.
- `notes_list_folders` now tolerates inaccessible Apple Notes folder references by skipping the bad reference and returning structured warnings instead of failing the entire folder listing with `Can't get object`.
- Phase 10 addressed a stale `20 Projetos` folder-reference report by reconciling the local folder cache from reachable live folders during successful `notes_list_folders` enumeration, without deleting indexed notes.

## Phase Completion Matrix

- Phase 1, automated tests: completed. The harness covers Markdown conversion, chunking, hashing/vector blobs, provider resolution, config normalization, logging redaction/rotation, health output, migrations, FTS5, sqlite-vec, RAG, hybrid search, links/backlinks, confirmation gates, attachment validation, and MCP STDIO smoke.
- Phase 2, schema metadata and migrations: completed. Metadata includes schema version and embedding provider/dimension/language. Provider or dimension changes mark stale vectors and preserve notes/FTS/link/attachment data.
- Phase 3, default embedding provider: completed. NaturalLanguage is the preferred local provider; hashing and noop providers remain local fallbacks.
- Phase 4, vector and hybrid search: completed. sqlite-vec is used for vector search, hybrid combines normalized lexical/vector scores, dedupes by note id, returns score components, and falls back to FTS5 with warnings.
- Phase 5, Apple Notes automation validation: completed for the core manual path in `AppleNotesMCP Test`; newer folder/bulk tools remain documented for opt-in manual validation.
- Phase 6, observability: completed. Default logging remains `error`, logs are allowlist-based, content-like fields are excluded, and size rotation keeps one backup.
- Phase 7, security review: completed. No HTTP listener, daemon, LaunchAgent, external API, OpenAI API, telemetry, NoteStore access, or shell execution from note content was added.
- Phase 8, README and final docs: completed. Documentation now reflects the current code and known limitations.
- Phase 9, packaging helpers: completed. `scripts/build-release.sh` and `scripts/doctor.sh` are documented and intentionally non-invasive.
- Phase 10, final acceptance and polish: completed. Final review fixed only acceptance bugs and documentation drift: root folder moves now accept `targetParentFolderPath: ""`, live folder listing reconciles stale local folder-cache branches, and current test counts/docs were updated.

## 1. Real Apple Notes Operations

Status: validated for the Phase 5 manual path on 2026-05-11.

What is confirmed:

- MCP server loads in Codex.
- Apple Notes automation permission works.
- `notes_health` returned `status: ok` and `permissions: apple_notes_automation_available`.
- `notes_list_accounts` returned the `iCloud` account.
- `notes_create_folder` created `AppleNotesMCP Test`; the second call returned `existing=true`.
- `notes_create`, `notes_read`, `notes_update` append/prepend/replace, `notes_move`, and `notes_delete` worked against a note created in the test folder.
- `notes_update` refused replace with `confirm=false`.
- `notes_delete` refused delete with `confirm=false` and deleted the test note with `confirm=true`.
- `notes_link`, `notes_extract_links`, and `notes_backlinks` worked through SQLite without corrupting the note body.
- `notes_sync_index` incremental with local embeddings completed, and FTS/RAG/hybrid search returned test-folder results.
- `notes_attach_file` with `real_attachment_preferred` returned an explicit `file_link_fallback` warning and did not pretend to create a native attachment.

Real limitations observed:

- Apple Notes returned ordered-list content as unordered-list HTML/Markdown during round-trip.
- Apple Notes returned Markdown links as underlined text without the original URL in the read-back HTML.
- Blockquote and code-block structure round-tripped as simplified text/monospace formatting.
- Apple Notes derives the displayed note title from the first body line. During validation, a replace body beginning with a heading changed the real note title. The server now preserves the existing title line when composing update HTML and indexes the actual title/body returned by JXA.
- A direct sandboxed STDIO title-preservation check using a temporary config could not drive Apple Notes automation from the spawned shell process; JXA returned `apple_notes_automation_failed` with `Parameter is missing.` Codex MCP tool calls remained functional, so this was treated as a local direct-run validation limitation rather than a product behavior change.

Final acceptance rule:

- All destructive or mutating tests must run in a dedicated folder named `AppleNotesMCP Test`, never against personal notes unless explicitly requested by the user.

## 2. Most Performant Low-Impact Embeddings

Status: implemented with Apple NaturalLanguage as the preferred local provider.

Rationale:

- Apple `NLEmbedding.sentenceEmbedding(for:)` is native to macOS and requires no model download, external runtime, daemon, or server.
- Apple documentation states sentence embeddings are dynamic and can return vectors for arbitrary sentences.
- Local check on this Mac:
  - English: dimension 512
  - Portuguese: dimension 640
  - Spanish: dimension 640
  - French: unavailable in the quick check
- This is a good fit for Apple Silicon laptops because it avoids keeping a heavy transformer model loaded.

Important constraint:

- `vec0` tables require a fixed vector dimension. NaturalLanguage dimensions vary by language, so provider or dimension changes trigger a controlled vector rebuild path.

Current provider behavior:

- `NaturalLanguageEmbeddingProvider` is the default requested provider.
- Default language is configurable and currently defaults to Portuguese (`pt`).
- If Portuguese sentence embeddings are unavailable, the resolver tries English (`en`).
- If no supported NaturalLanguage sentence embedding is available, the resolver falls back to `HashingEmbeddingProvider` and exposes warnings in health/config output.
- `HashingEmbeddingProvider` and `NoopEmbeddingProvider` remain local fallback paths.
- The provider is created lazily by `EmbeddingService`.

Performance defaults:

- No background sync.
- No polling loop.
- No watcher.
- `maxEmbeddingConcurrency = 1`.
- Generate embeddings only during explicit sync, rebuild, create, or update.
- Chunk only note body text, not attachments.
- Keep chunk size near 500-900 estimated tokens, overlap 80-120 tokens.
- Always `LIMIT` search queries.
- Use FTS5 first for hybrid search; use vector search only for semantic expansion/ranking.

Not implemented:

- Core ML, MLX, llama.cpp, downloaded embedding models, external APIs, and OpenAI API calls are not part of the current implementation.

Sources reviewed:

- Apple `NLEmbedding`: https://developer.apple.com/documentation/naturallanguage/nlembedding
- Apple text similarity guide: https://developer.apple.com/documentation/naturallanguage/finding_similarities_between_pieces_of_text
- MLX Swift: https://github.com/ml-explore/mlx-swift
- llama.cpp: https://github.com/ggml-org/llama.cpp
- all-MiniLM-L6-v2 model card: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- bge-small-en-v1.5 model card: https://huggingface.co/BAAI/bge-small-en-v1.5

## 3. Confirm Apple Notes Automation Behavior

Status: completed for the core Phase 5 manual path; opt-in manual coverage remains documented for folder and bulk-note tools added later.

The current scripts use JXA through `/usr/bin/osascript`, targeting `/System/Applications/Notes.app`.

Confirmed during the 2026-05-11 manual path:

- Account listing worked for the iCloud account.
- Creating an existing folder returned success with `existing=true`.
- Note create/read/update/move/delete worked in `AppleNotesMCP Test`.
- Replace and delete confirmation gates worked.
- Link extraction and backlinks worked through SQLite.
- Incremental sync and FTS/RAG/hybrid search worked against indexed test content.
- Attachment real insertion remained best-effort and returned explicit `file_link_fallback`.

Still documented as opt-in manual validation, because these mutate real Apple Notes:

- Folder hierarchy listing across accounts.
- Folder rename, move, delete, and merge.
- Bulk move/archive/delete dry run and confirmed delete.
- Real attachment behavior on other macOS/Notes versions.
- iCloud sync timing and UI fidelity.

Current folder-listing behavior:

- `notes_list_folders` uses JXA enumeration through `osascript`.
- Inaccessible folder references are skipped and reported through `warnings`.
- After successful live enumeration, the local folder cache is reconciled to reachable folders for the selected scope; this removes stale branches such as the reported `20 Projetos` container without deleting indexed notes.
- A direct shell-run validation from this sandbox can still fail with `Parameter is missing`; Codex MCP tool calls are the authoritative manual path for Apple Notes automation validation.

Do not attempt to write to Apple Notes internal SQLite files.

## 4. Test Plan

Status: implemented for safe automated coverage; manual Apple Notes validation remains separate.

Current split:

- Unit tests for pure Swift logic.
- SQLite integration tests using temporary databases.
- MCP smoke tests using STDIO and temporary config.
- Manual or opt-in Apple Notes integration tests using `AppleNotesMCP Test`.
- Cross-process concurrency tests.

See `docs/TEST_PLAN.md`.

## 5. What Can Be Tested Automatically

The assistant or CI can test automatically:

- Build.
- MCP initialize/tools/resources/prompts.
- Config loading.
- Provider resolution and embedding metadata normalization.
- Markdown to HTML.
- HTML to Markdown best effort.
- Apple Notes title-line preservation helpers.
- Chunking.
- Hashing.
- SQLite migrations.
- FTS5 search.
- Folder summaries, folder-path cache updates, metadata search, and bulk delete dry run.
- sqlite-vec table creation and vector search.
- RAG search over sqlite-vec fixtures.
- Hybrid ranking score components, filters, dedupe, and FTS fallback.
- Link extraction/backlinks in SQLite.
- Cross-process sync lock behavior.
- Safe logging field allowlist, note id truncation, and size rotation.
- Health output redaction.
- Attachment path validation.
- Destructive confirmation gates.
- Automation stderr redaction.

The no-daemon, no-LaunchAgent, no-HTTP-listener, no-external-API, no-OpenAI-API, and no-NoteStore-access rules are confirmed by code review and build/test behavior, not by a network-probing automated test.

Manual or opt-in tests are still required for:

- Real Apple Notes permission prompts.
- Actual Notes folder/note create/update/delete/move.
- Visual fidelity of rich text in the Notes UI.
- Real attachment behavior.
- iCloud sync timing.

## 6. Schema and Migration Plan

Status: implemented with schema version 2.

Current schema metadata:

- `metadata.schema_version`.
- `metadata.embedding_provider`.
- `metadata.embedding_dimension`.
- `metadata.embedding_language`.
- `metadata.last_sync_at` when sync has run.

Current migration behavior:

- Ordered migrations create the initial schema and add embedding metadata support.
- Database files are not deleted or recreated during migration.
- Notes, folders, FTS, links, and attachments are preserved.
- Provider, language, or dimension changes mark incompatible vectors stale.
- `vec_chunks` is dropped and recreated only for vector-table compatibility, inside a transaction.

Do not delete or recreate the database file during migration.

Migration rules:

- Use WAL.
- Keep write transactions short.
- Avoid AppleScript while inside SQLite write transactions.
- For incompatible vector dimensions, drop/recreate only vector tables inside a transaction and mark vectors stale; do not drop notes/FTS data.

## 7. Hybrid Ranking Plan

Status: implemented for the local SQLite search path.

Current hybrid search:

- Runs FTS5 with `candidateLimit = max(limit * 5, 30)`.
- Runs sqlite-vec vector search with the same candidate limit.
- Normalizes lexical and vector scores independently.
- Deduplicates by note id.
- Prefers strong lexical matches when combined scores are close.
- Returns matched chunk snippets and `chunkIndex` for vector matches when available.
- Includes score components:
  - `lexicalScore`
  - `vectorScore`
  - `combinedScore`
  - `rankReason`
- Keeps `lexicalWeight` default at `0.65` and `vectorWeight` default at `0.35`.
- Falls back to FTS5 with a warning if sqlite-vec vector search is unavailable.

## 8. Observability Plan

Status: implemented for the safe local logging path.

Current log policy:

- Default `logLevel = error`.
- Never log full note bodies.
- Never log full Markdown, full HTML, raw automation HTML, note titles, search queries, attachment paths, or attachment contents.
- Safe fields:
  - operation name
  - duration
  - counts
  - typed error code
  - truncated note id
  - sync mode
  - provider/dimension/language metadata without content
- Logger sanitization is centralized around an allowlist.
- Rotation by size keeps one `.1` backup file.

Optional diagnostics:

- `notes_diagnostics` was not added.
- `notes_health` exposes schema version, embedding provider/language/dimension, vector availability, last sync, log level, and log path without note content.

## 9. Packaging Plan

Status: completed with simple SwiftPM build plus lightweight local helper scripts.

Keep packaging simple:

- `swift build -c release`
- `scripts/build-release.sh`
- `scripts/doctor.sh`
- `codex mcp add apple-notes -- /ABSOLUTE/PATH/.build/release/AppleNotesMCP`
- No installer daemon.
- No LaunchAgent.
- No HTTP service.

Added:

- `scripts/build-release.sh` wraps the release build and verifies the binary exists.
- `scripts/doctor.sh` checks Swift, Apple Notes app presence, release binary presence, Codex config hints, and a minimal `notes_health` MCP smoke test.

Not added:

- No `scripts/register-codex.sh`; README keeps the explicit Codex CLI command instead of adding another persistent setup path.
- No separate `docs/MANUAL_TEST_RUNBOOK.md`; the manual runbook remains in `docs/TEST_PLAN.md`.

## 10. Security Review

Status: completed on 2026-05-12.

Final security checks:

- Dependencies pinned.
- `sqlite-vec` source and SHA256 documented.
- No external API calls by default.
- No OpenAI API calls by default.
- No telemetry.
- No HTTP listener.
- No daemon or LaunchAgent.
- File attachment paths are expanded and validated.
- No shell execution from note content.
- JXA scripts take JSON input and return JSON envelopes only.
- Errors are typed and structured.
- Logs redact content-like fields.
- The server never reads or writes Apple Notes internal databases.

Findings and decisions:

- Attachment path validation was tightened. `notes_attach_file` now expands `~`, requires an absolute path, resolves symlinks, and accepts only existing readable regular files. Relative paths, directories, and special files are rejected before any Apple Notes mutation.
- Raw `osascript` stderr is no longer returned verbatim. It is classified as permission, JavaScript syntax, or redacted automation stderr to avoid leaking note content, file paths, or system details from automation failures.
- Folder paths for `notes_create_folder`, `notes_create`, and `notes_move` are normalized through the same folder-path validation used by folder and bulk operations.
- Tool logging remains allowlist-based and does not record note bodies, Markdown, HTML, titles, search queries, prompt arguments, attachment paths, or attachment contents.
- `notes_health` returns status/config/count/embedding/permission/limitation metadata only. It intentionally includes local `databasePath` and `logPath` for diagnostics, but never note bodies, note titles, search queries, prompt arguments, attachment contents, or raw HTML.
- `notes_list_folders` returns folder id/account/path/parent/count metadata only. Folder names and paths are exposed by design because listing folders is the tool's purpose; it does not return note content.
- Destructive operations require explicit confirmation: note delete, folder delete, folder merge, and bulk delete with `dryRun=false`. Bulk delete defaults to `dryRun=true`.
- Search and read tools can return note content by design when explicitly invoked. This remains a documented capability, not a logging behavior.

## Recommended Next Steps

The original end-to-end implementation work is complete.

Optional future work, only if explicitly requested:

1. Run opt-in manual Apple Notes validation for the newly added folder and bulk-note tools in `AppleNotesMCP Test`.
2. Run targeted manual validation of `notes_move_folder` root moves with `targetParentFolderPath: ""` if that path is used again.
