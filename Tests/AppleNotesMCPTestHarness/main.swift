import Foundation

#if DEBUG
import CSQLite
@testable import AppleNotesMCPLibrary

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: UInt

    var description: String {
        "\(file):\(line): \(message)"
    }
}

private struct TestCase {
    let name: String
    let body: () throws -> Void
}

private final class TestRunner {
    private var tests: [TestCase] = []

    func test(_ name: String, _ body: @escaping () throws -> Void) {
        tests.append(TestCase(name: name, body: body))
    }

    func run() -> Int32 {
        var failures = 0
        for test in tests {
            do {
                try test.body()
                print("PASS \(test.name)")
            } catch {
                failures += 1
                fputs("FAIL \(test.name): \(error)\n", stderr)
            }
        }
        print("AppleNotesMCPTestHarness: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0 ? 0 : 1
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "Expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(message: message(), file: "\(file)", line: line)
    }
}

private func require<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "Required value was nil",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(message: message(), file: "\(file)", line: line)
    }
    return value
}

private func expectNotesError(
    code: String,
    _ body: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    do {
        try body()
    } catch let error as NotesError {
        try expect(error.code == code, "Expected \(code), got \(error.code)", file: file, line: line)
        return
    } catch {
        throw TestFailure(message: "Expected NotesError \(code), got \(error)", file: "\(file)", line: line)
    }
    throw TestFailure(message: "Expected NotesError \(code)", file: "\(file)", line: line)
}

private let runner = TestRunner()

runner.test("Markdown to HTML covers supported blocks and inline formatting") {
    let markdown = """
    # Title

    A **bold** and *italic* paragraph with [link](https://example.com) and `code`.

    - First
    - Second

    1. One
    2. Two

    | Name | Value |
    | --- | --- |
    | Alpha | Beta |

    > Quoted text

    ```
    let value = 1 < 2
    ```
    """

    let html = MarkdownConverter().markdownToHTML(markdown)

    try expect(html.contains("<h1>Title</h1>"))
    try expect(html.contains("<strong>bold</strong>"))
    try expect(html.contains("<em>italic</em>"))
    try expect(html.contains(#"<a href="https://example.com">link</a>"#))
    try expect(html.contains("<code>code</code>"))
    try expect(html.contains("<ul>"))
    try expect(html.contains("<ol>"))
    try expect(html.contains("<table>"))
    try expect(html.contains("<blockquote>"))
    try expect(html.contains("<pre><code>let value = 1 &lt; 2</code></pre>"))
}

runner.test("HTML to Markdown is readable and tolerates malformed HTML") {
    let html = """
    <h1>Title</h1><p>Body &amp; details</p><ul><li>First</li><li>Second</li></ul><strong>open
    """

    let markdown = MarkdownConverter().htmlToMarkdown(html)

    try expect(markdown.contains("# Title"))
    try expect(markdown.contains("Body & details"))
    try expect(markdown.contains("- First"))
    try expect(markdown.contains("- Second"))
    try expect(markdown.contains("open"))
}

runner.test("Apple Notes update HTML preserves title line") {
    let title = "MCP Manual Test"
    let currentHTML = "<div>MCP Manual Test</div>\n<p>Existing body</p>"
    let incomingHTML = "<h1>Replacement Validation</h1>\n<p>New body</p>"

    let replaced = composeAppleNotesUpdateHTML(
        title: title,
        currentHTML: currentHTML,
        incomingHTML: incomingHTML,
        mode: "replace"
    )
    try expect(replaced.hasPrefix("<div>MCP Manual Test</div>\n<h1>Replacement Validation</h1>"))

    let prepended = composeAppleNotesUpdateHTML(
        title: title,
        currentHTML: currentHTML,
        incomingHTML: "<p>Prepended body</p>",
        mode: "prepend"
    )
    try expect(prepended == "<div>MCP Manual Test</div>\n<p>Prepended body</p>\n<p>Existing body</p>")

    let appendedFromCachedCreate = composeAppleNotesUpdateHTML(
        title: title,
        currentHTML: "<p>Existing body without title</p>",
        incomingHTML: "<p>Appended body</p>",
        mode: "append"
    )
    try expect(appendedFromCachedCreate.hasPrefix("<div>MCP Manual Test</div>\n<p>Existing body without title</p>"))
}

runner.test("Apple Notes rename HTML replaces only the leading title line") {
    let renamed = composeAppleNotesRenameHTML(
        oldTitle: "Old Title",
        newTitle: "New Title",
        currentHTML: "<div>Old Title</div>\n<p>Body stays</p>"
    )
    try expect(renamed == "<div>New Title</div>\n<p>Body stays</p>")

    let inserted = composeAppleNotesRenameHTML(
        oldTitle: "Old Title",
        newTitle: "New Title",
        currentHTML: "<p>Body without title</p>"
    )
    try expect(inserted == "<div>New Title</div>\n<p>Body without title</p>")
}

runner.test("Folder path normalization supports root move target") {
    try expect(normalizeFolderPath(" / Projects // Active / ") == "Projects/Active")
    try expect(normalizeFolderPath("") == "")
    try expect(normalizeFolderPath(" / ") == "")
    let rootMoveArgs: [String: MCPValue] = ["targetParentFolderPath": .string("")]
    let rootTarget = try rootMoveArgs.requiredString("targetParentFolderPath", allowEmpty: true)
    try expect(rootTarget == "")
    try expectNotesError(code: "invalid_params") {
        _ = try rootMoveArgs.requiredString("targetParentFolderPath")
    }
    try expectNotesError(code: "invalid_params") {
        _ = try requiredFolderPath(" / ")
    }
}

runner.test("Empty text creates no chunks") {
    try expect(Chunker().chunks(noteId: "note", text: " \n ").isEmpty)
}

runner.test("Short text creates one stable chunk") {
    let chunks = Chunker().chunks(noteId: "note", text: "  short note body  ")

    try expect(chunks.count == 1)
    try expect(chunks[0].noteId == "note")
    try expect(chunks[0].index == 0)
    try expect(chunks[0].text == "short note body")
    try expect(chunks[0].textHash == stableHash("short note body"))
    try expect(chunks[0].tokenEstimate == 3)
}

runner.test("Long text creates ordered overlapping chunks") {
    let tokens = (0..<2_000).map { "token\($0)" }
    let chunks = Chunker().chunks(noteId: "note", text: tokens.joined(separator: " "))

    try expect(chunks.count > 1)
    try expect(chunks.map(\.index) == Array(0..<chunks.count))
    try expect(chunks[0].tokenEstimate == 700)
    try expect(chunks[1].tokenEstimate == 700)

    let firstTokens = chunks[0].text.split(separator: " ").map(String.init)
    let secondTokens = chunks[1].text.split(separator: " ").map(String.init)
    try expect(firstTokens.suffix(100) == secondTokens.prefix(100))
}

runner.test("Stable hash is deterministic FNV-1a 64") {
    try expect(stableHash("hello") == "a430d84680aabd0b")
    try expect(stableHash("hello") == stableHash("hello"))
    try expect(stableHash("hello") != stableHash("Hello"))
}

runner.test("Vector blob round trip uses little-endian float bits") {
    let vector: [Float] = [0, 1, -2.5, .pi]
    let blob = vectorToBlob(vector)

    try expect(blob.count == vector.count * MemoryLayout<Float>.size)
    try expect(blobToVector(blob) == vector)
    try expect(blobToVector(Data([0x00, 0x01])) == [])
}

runner.test("Embedding provider selection prefers NaturalLanguage Portuguese when available") {
    let resolution = EmbeddingProviderResolver.resolve(
        requestedProvider: NaturalLanguageEmbeddingProvider.providerName,
        requestedLanguage: "pt",
        requestedDimension: 384
    )

    if let portuguese = NaturalLanguageEmbeddingProvider.profileIfAvailable(language: "pt") {
        try expect(resolution.profile == portuguese)
        try expect(resolution.warnings.isEmpty)
    } else if let english = NaturalLanguageEmbeddingProvider.profileIfAvailable(language: "en") {
        try expect(resolution.profile == english)
        try expect(resolution.warnings.contains { $0.contains("'pt'") && $0.contains("'en'") })
    } else {
        try expect(resolution.profile.provider == HashingEmbeddingProvider.providerName)
        try expect(resolution.profile.dimension == 384)
        try expect(!resolution.warnings.isEmpty)
    }
}

runner.test("Embedding provider selection falls back when language is unavailable") {
    let resolution = EmbeddingProviderResolver.resolve(
        requestedProvider: NaturalLanguageEmbeddingProvider.providerName,
        requestedLanguage: "zz",
        requestedDimension: 384
    )

    if let english = NaturalLanguageEmbeddingProvider.profileIfAvailable(language: "en") {
        try expect(resolution.profile == english)
        try expect(resolution.warnings.contains { $0.contains("'zz'") && $0.contains("'en'") })
    } else {
        try expect(resolution.profile.provider == HashingEmbeddingProvider.providerName)
        try expect(resolution.profile.dimension == 384)
        try expect(resolution.warnings.contains { $0.contains(HashingEmbeddingProvider.providerName) })
    }
}

runner.test("Embedding providers report their active dimensions") {
    let hashing = HashingEmbeddingProvider(dimension: 32)
    try expect(hashing.dimension == 32)

    if let profile = NaturalLanguageEmbeddingProvider.profileIfAvailable(language: "pt")
        ?? NaturalLanguageEmbeddingProvider.profileIfAvailable(language: "en") {
        let provider = NaturalLanguageEmbeddingProvider(
            language: profile.language,
            dimension: profile.dimension
        )
        try expect(provider.dimension == profile.dimension)
        try expect(profile.dimension > 0)
    }
}

runner.test("AppConfig normalizes embedding provider metadata") {
    let config = AppConfig(
        defaultAccount: "iCloud",
        allowOnMyMac: true,
        databasePath: "/tmp/index.sqlite",
        logPath: "/tmp/server.log",
        logLevel: "error",
        embeddingsEnabled: true,
        maxEmbeddingConcurrency: 0,
        maxSyncConcurrency: 0,
        syncLockPath: "/tmp/sync.lock",
        embeddingProvider: NaturalLanguageEmbeddingProvider.providerName,
        embeddingLanguage: "pt-BR",
        embeddingDimension: 384
    ).normalized()

    let expected = EmbeddingProviderResolver.resolve(
        requestedProvider: NaturalLanguageEmbeddingProvider.providerName,
        requestedLanguage: "pt-BR",
        requestedDimension: 384
    )
    try expect(config.embeddingProfile == expected.profile)
    try expect(config.maxEmbeddingConcurrency == 1)
    try expect(config.maxSyncConcurrency == 1)
}

runner.test("AppLogger keeps only safe fields and truncates note ids") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleNotesMCPLogger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let logPath = directory.appendingPathComponent("server.log").path
    let logger = try AppLogger(path: logPath, level: "debug")
    logger.info("unsafe operation\nname", fields: [
        "duration_ms": "42",
        "noteId": "1234567890abcdef",
        "mode": "full",
        "nativeApplied": "false",
        "fallback": "sqlite_metadata",
        "reason": "note_object_or_ui_element_unavailable",
        "indexed": "7",
        "provider": NaturalLanguageEmbeddingProvider.providerName,
        "embeddingDimension": "640",
        "bodyMarkdown": "SECRET_MARKDOWN_BODY",
        "body_html": "<p>SECRET_HTML_BODY</p>",
        "rawHTML": "<div>SECRET_RAW_HTML</div>",
        "attachmentContent": "SECRET_ATTACHMENT_CONTENT",
        "message": "SECRET_ERROR_MESSAGE",
        "query": "SECRET_QUERY_TEXT",
        "title": "SECRET_TITLE"
    ])

    let log = try String(contentsOfFile: logPath, encoding: .utf8)
    try expect(log.contains("operation=unsafe_operation_name"))
    try expect(log.contains("duration_ms=42"))
    try expect(log.contains("noteId=1234567890ab"))
    try expect(log.contains("mode=full"))
    try expect(log.contains("nativeApplied=false"))
    try expect(log.contains("fallback=sqlite_metadata"))
    try expect(log.contains("reason=note_object_or_ui_element_unavailable"))
    try expect(log.contains("indexed=7"))
    try expect(log.contains("provider=\(NaturalLanguageEmbeddingProvider.providerName)"))
    try expect(log.contains("embeddingDimension=640"))
    for leaked in [
        "SECRET_MARKDOWN_BODY",
        "SECRET_HTML_BODY",
        "SECRET_RAW_HTML",
        "SECRET_ATTACHMENT_CONTENT",
        "SECRET_ERROR_MESSAGE",
        "SECRET_QUERY_TEXT",
        "SECRET_TITLE",
        "bodyMarkdown",
        "body_html",
        "rawHTML",
        "attachmentContent",
        "message",
        "query",
        "title"
    ] {
        try expect(!log.contains(leaked), "Log leaked unsafe field or value: \(leaked)")
    }
}

runner.test("AppLogger rotates by size with one backup file") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleNotesMCPLoggerRotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let logPath = directory.appendingPathComponent("server.log").path
    try String(repeating: "x", count: 128).write(toFile: logPath, atomically: true, encoding: .utf8)
    let logger = try AppLogger(path: logPath, level: "debug", maxBytes: 64)
    logger.info("rotation_check", fields: ["duration_ms": "1"])

    let current = try String(contentsOfFile: logPath, encoding: .utf8)
    let rotatedPath = logPath + ".1"
    try expect(FileManager.default.fileExists(atPath: rotatedPath))
    try expect(current.contains("operation=rotation_check"))
    try expect(current.contains("duration_ms=1"))
}

runner.test("Tool logging redacts arguments and result metadata") {
    let fixture = try StoreFixture(embeddingDimension: 4, logLevel: "info")
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(
        id: "tool-log-secret",
        title: "SECRET_LOG_TITLE",
        bodyMarkdown: "SECRET_LOG_BODY"
    ))

    let result = try waitForAsync {
        await service.callTool(
            name: "notes_search_notes",
            arguments: [
                "titleQuery": .string("SECRET_LOG"),
                "query": .string("SECRET_QUERY_TEXT"),
                "filePath": .string("/private/tmp/SECRET_PATH"),
                "bodyMarkdown": .string("SECRET_ARG_BODY")
            ]
        )
    }
    try expect(result.1 == false)

    let log = try String(contentsOfFile: fixture.logPath, encoding: .utf8)
    try expect(log.contains("operation=notes_search_notes"))
    try expect(log.contains("count=1"))
    for leaked in [
        "SECRET_LOG_TITLE",
        "SECRET_LOG_BODY",
        "SECRET_QUERY_TEXT",
        "SECRET_PATH",
        "SECRET_ARG_BODY",
        "titleQuery",
        "query",
        "filePath",
        "bodyMarkdown"
    ] {
        try expect(!log.contains(leaked), "Tool log leaked unsafe field or value: \(leaked)")
    }
}

runner.test("Automation stderr redaction does not expose raw stderr") {
    let redacted = sanitizeAutomationError(
        "execution error: SECRET_NOTE_BODY /Users/example/private.txt"
    )
    try expect(redacted == "redacted_osascript_stderr")
    try expect(!redacted.contains("SECRET_NOTE_BODY"))
    try expect(!redacted.contains("/Users/example/private.txt"))

    try expect(sanitizeAutomationError("Not authorized to send Apple events") == "permission_denied")
    try expect(sanitizeAutomationError("SyntaxError: Expected ;") == "javascript_syntax_error")
}

runner.test("Update script avoids body read-back after write") {
    try expect(NotesService.scriptUpdateNote.contains("updateNoteBodyById"))
    try expect(NotesService.scriptUpdateNote.contains("updateNoteBodyByTitle"))
    try expect(!NotesService.scriptUpdateNote.contains("return ok(noteInfo"))
}

runner.test("Move script avoids read-back and supports title fallback") {
    try expect(NotesService.scriptMoveNote.contains("moveNoteById"))
    try expect(NotesService.scriptMoveNote.contains("moveNoteByTitle"))
    try expect(NotesService.scriptMoveNote.contains("sourceFolderPath"))
    try expect(!NotesService.scriptMoveNote.contains("return ok(noteInfo"))
}

runner.test("Experimental UI scripts return classified safe reasons") {
    try expect(NotesService.scriptAppendNativeTagsUI.contains("classifiedUIError"))
    try expect(NotesService.scriptAppendNativeNoteLinkUI.contains("classifiedUIError"))
    try expect(!NotesService.scriptAppendNativeTagsUI.contains("String(e)"))
    try expect(!NotesService.scriptAppendNativeNoteLinkUI.contains("String(e)"))
}

runner.test("notes_health exposes safe observability fields only") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    try fixture.store.upsertNote(makeNote(
        id: "health-secret",
        title: "SECRET_HEALTH_TITLE",
        bodyMarkdown: "SECRET_HEALTH_BODY"
    ))
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)

    let health = try waitForAsync {
        await service.healthValue(permissions: "apple_notes_automation_available")
    }
    let object = try require(health.objectValue)

    for key in [
        "schemaVersion",
        "embeddingProvider",
        "embeddingLanguage",
        "embeddingDimension",
        "vectorSearchAvailable",
        "lastSync",
        "logLevel",
        "logPath"
    ] {
        try expect(object[key] != nil, "Missing health key \(key)")
    }
    try expect(object["logLevel"]?.stringValue == "error")
    try expect(object["logPath"]?.stringValue == fixture.logPath)

    let healthJSON = valueToJSONString(health)
    for unsafe in [
        "bodyHTML",
        "bodyMarkdown",
        "body_html",
        "body_markdown",
        "rawHTML",
        "attachmentContent",
        "SECRET_HEALTH_TITLE",
        "SECRET_HEALTH_BODY"
    ] {
        try expect(!healthJSON.contains(unsafe), "Health exposed unsafe key \(unsafe)")
    }
}

runner.test("Store creates current schema with WAL, FTS5, and sqlite-vec") {
    let fixture = try StoreFixture(embeddingDimension: 4)

    try expect(FileManager.default.fileExists(atPath: fixture.databasePath))
    let journalMode = try sqliteStringScalar(path: fixture.databasePath, sql: "PRAGMA journal_mode")
    try expect(journalMode == "wal")
    try expect(fixture.store.vectorAvailable)

    for table in ["metadata", "notes", "folders", "attachments", "links", "chunks", "notes_fts", "vec_chunks"] {
        let exists = try sqliteTableExists(path: fixture.databasePath, tableName: table)
        try expect(
            exists,
            "Expected SQLite object \(table) to exist"
        )
    }

    let schemaVersion = try sqliteStringScalar(
        path: fixture.databasePath,
        sql: "SELECT value FROM metadata WHERE key = 'schema_version'"
    )
    let embeddingProvider = try sqliteStringScalar(
        path: fixture.databasePath,
        sql: "SELECT value FROM metadata WHERE key = 'embedding_provider'"
    )
    let embeddingDimension = try sqliteStringScalar(
        path: fixture.databasePath,
        sql: "SELECT value FROM metadata WHERE key = 'embedding_dimension'"
    )
    let embeddingLanguage = try sqliteStringScalar(
        path: fixture.databasePath,
        sql: "SELECT value FROM metadata WHERE key = 'embedding_language'"
    )
    let staleColumn = try sqliteStringScalar(
        path: fixture.databasePath,
        sql: "SELECT name FROM pragma_table_info('chunks') WHERE name = 'embedding_stale'"
    )
    try expect(fixture.store.schemaVersion == SQLiteStore.currentSchemaVersion)
    try expect(schemaVersion == "\(SQLiteStore.currentSchemaVersion)")
    try expect(embeddingProvider == HashingEmbeddingProvider.providerName)
    try expect(embeddingDimension == "4")
    try expect(embeddingLanguage == HashingEmbeddingProvider.language)
    try expect(staleColumn == "embedding_stale")
}

runner.test("Embedding metadata migration preserves data and marks incompatible vectors stale") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleNotesMCPMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databasePath = directory.appendingPathComponent("index.sqlite").path
    let logPath = directory.appendingPathComponent("server.log").path

    do {
        let logger = try AppLogger(path: logPath, level: "error")
        let store = try SQLiteStore(path: databasePath, logger: logger, embeddingDimension: 4)
        try store.upsertNote(makeNote(
            id: "note-migration",
            title: "Migration Note",
            bodyMarkdown: "Uniquephase indexed body"
        ))
        try store.replaceChunks(
            noteId: "note-migration",
            chunks: [makeChunk(id: "chunk-migration", noteId: "note-migration", index: 0, text: "Uniquephase indexed body")],
            embeddings: ["chunk-migration": [1, 0, 0, 0]]
        )
        try store.insertAttachment(AttachmentRecord(
            id: "attachment-migration",
            noteId: "note-migration",
            filePath: "/private/tmp/example.txt",
            fileURL: "file:///private/tmp/example.txt",
            filename: "example.txt",
            mimeType: "text/plain",
            sizeBytes: 12,
            attachedAs: "file_link_fallback",
            createdAt: "2026-01-01T00:00:00Z"
        ))
        try store.insertLink(LinkRecord(
            id: "link-migration",
            sourceNoteId: "note-migration",
            targetNoteId: nil,
            targetTitle: "Target",
            linkText: "Target",
            linkType: "wikilink_detected",
            createdAt: "2026-01-01T00:00:00Z"
        ))
    }

    let logger = try AppLogger(path: logPath, level: "error")
    let migrated = try SQLiteStore(path: databasePath, logger: logger, embeddingDimension: 8)

    try expect(migrated.schemaVersion == SQLiteStore.currentSchemaVersion)
    let migratedMetadata = try require(migrated.embeddingMetadata())
    try expect(migratedMetadata.dimension == 8)
    let staleEmbeddingCount = try migrated.staleEmbeddingCount()
    try expect(staleEmbeddingCount == 1)
    let migratedNote = try require(migrated.noteById("note-migration"))
    try expect(migratedNote.title == "Migration Note")
    let ftsResults = try migrated.searchFTS(query: "uniquephase", limit: 5, accountName: nil, folderPath: nil)
    try expect(ftsResults.map(\.noteId) == ["note-migration"])
    let attachmentCount = try sqliteIntScalar(path: databasePath, sql: "SELECT COUNT(*) FROM attachments")
    let linkCount = try sqliteIntScalar(path: databasePath, sql: "SELECT COUNT(*) FROM links")
    let chunkCount = try sqliteIntScalar(path: databasePath, sql: "SELECT COUNT(*) FROM chunks")
    let chunkStale = try sqliteIntScalar(path: databasePath, sql: "SELECT embedding_stale FROM chunks WHERE id = 'chunk-migration'")
    try expect(attachmentCount == 1)
    try expect(linkCount == 1)
    try expect(chunkCount == 1)
    try expect(chunkStale == 1)

    let staleResults = try migrated.searchVector(
        queryVector: [1, 0, 0, 0, 0, 0, 0, 0],
        limit: 5,
        accountName: nil,
        folderPath: nil
    )
    try expect(staleResults.isEmpty)
}

runner.test("Embedding metadata change marks vectors stale without dropping notes") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleNotesMCPProfileChange-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databasePath = directory.appendingPathComponent("index.sqlite").path
    let logPath = directory.appendingPathComponent("server.log").path

    do {
        let logger = try AppLogger(path: logPath, level: "error")
        let store = try SQLiteStore(
            path: databasePath,
            logger: logger,
            embeddingDimension: 4,
            embeddingProvider: HashingEmbeddingProvider.providerName,
            embeddingLanguage: HashingEmbeddingProvider.language
        )
        try store.upsertNote(makeNote(
            id: "note-profile",
            title: "Profile Note",
            bodyMarkdown: "Profile change indexed body"
        ))
        try store.replaceChunks(
            noteId: "note-profile",
            chunks: [makeChunk(id: "chunk-profile", noteId: "note-profile", index: 0, text: "Profile change indexed body")],
            embeddings: ["chunk-profile": [1, 0, 0, 0]]
        )
    }

    let logger = try AppLogger(path: logPath, level: "error")
    let migrated = try SQLiteStore(
        path: databasePath,
        logger: logger,
        embeddingDimension: 4,
        embeddingProvider: NaturalLanguageEmbeddingProvider.providerName,
        embeddingLanguage: "pt"
    )

    let metadata = try require(migrated.embeddingMetadata())
    try expect(metadata.provider == NaturalLanguageEmbeddingProvider.providerName)
    try expect(metadata.language == "pt")
    try expect(metadata.dimension == 4)
    let staleEmbeddingCount = try migrated.staleEmbeddingCount()
    let migratedNote = try require(migrated.noteById("note-profile"))
    try expect(staleEmbeddingCount == 1)
    try expect(migratedNote.title == "Profile Note")

    let ftsResults = try migrated.searchFTS(query: "profile", limit: 5, accountName: nil, folderPath: nil)
    try expect(ftsResults.map(\.noteId) == ["note-profile"])
    let chunkCount = try sqliteIntScalar(path: databasePath, sql: "SELECT COUNT(*) FROM chunks")
    let vectorResults = try migrated.searchVector(
        queryVector: [1, 0, 0, 0],
        limit: 5,
        accountName: nil,
        folderPath: nil
    )
    try expect(chunkCount == 1)
    try expect(vectorResults.isEmpty)
}

runner.test("FTS search finds notes, applies filters, and enforces limit") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    try fixture.store.upsertNote(makeNote(
        id: "note-1",
        title: "Roadmap",
        accountName: "iCloud",
        folderPath: "Projects",
        bodyMarkdown: "Alpha launch plan"
    ))
    try fixture.store.upsertNote(makeNote(
        id: "note-2",
        title: "Archive",
        accountName: "On My Mac",
        folderPath: "Archive",
        bodyMarkdown: "Alpha archived plan"
    ))

    let allResults = try fixture.store.searchFTS(query: "alpha", limit: 10, accountName: nil, folderPath: nil)
    try expect(Set(allResults.map(\.noteId)) == ["note-1", "note-2"])

    let filtered = try fixture.store.searchFTS(query: "alpha", limit: 10, accountName: "iCloud", folderPath: "Projects")
    try expect(filtered.map(\.noteId) == ["note-1"])

    let limited = try fixture.store.searchFTS(query: "alpha", limit: 1, accountName: nil, folderPath: nil)
    try expect(limited.count == 1)
}

runner.test("Folder summaries include ids, parent ids, and direct counts") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    try fixture.store.upsertFolder(accountName: "iCloud", path: "Projects")
    try fixture.store.upsertFolder(accountName: "iCloud", path: "Projects/Archive")
    try fixture.store.upsertFolder(accountName: "iCloud", path: "Projects/Active")
    try fixture.store.upsertNote(makeNote(
        id: "folder-note-root",
        title: "Root Folder Note",
        accountName: "iCloud",
        folderPath: "Projects",
        bodyMarkdown: "Root body"
    ))
    try fixture.store.upsertNote(makeNote(
        id: "folder-note-archive",
        title: "Archive Folder Note",
        accountName: "iCloud",
        folderPath: "Projects/Archive",
        bodyMarkdown: "Archive body"
    ))

    let summaries = try fixture.store.listFolderSummaries(accountName: "iCloud")
    let root = try require(summaries.first { $0.path == "Projects" })
    let archive = try require(summaries.first { $0.path == "Projects/Archive" })
    try expect(root.parentId == nil)
    try expect(root.childCount == 2)
    try expect(root.noteCount == 1)
    try expect(archive.parentId == root.id)
    try expect(archive.childCount == 0)
    try expect(archive.noteCount == 1)

    let changed = try fixture.store.updateFolderPath(
        accountName: "iCloud",
        oldPath: "Projects/Archive",
        newPath: "Projects/Done"
    )
    try expect(changed == 1)
    let moved = try require(fixture.store.noteById("folder-note-archive"))
    try expect(moved.folderPath == "Projects/Done")
}

runner.test("Folder cache reconciliation removes stale Apple Notes branches without deleting notes") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    try fixture.store.upsertFolder(accountName: "iCloud", path: "20 Projetos")
    try fixture.store.upsertFolder(accountName: "iCloud", path: "20 Projetos/Legacy")
    try fixture.store.upsertFolder(accountName: "iCloud", path: "Contabilizei")
    try fixture.store.upsertFolder(accountName: "On My Mac", path: "Local")
    try fixture.store.upsertNote(makeNote(
        id: "stale-folder-note",
        title: "Stale Folder Note",
        accountName: "iCloud",
        folderPath: "20 Projetos/Legacy",
        bodyMarkdown: "Note content remains searchable"
    ))

    let removed = try fixture.store.replaceFolderCache(
        accountName: "iCloud",
        liveFolders: [
            (accountName: "iCloud", path: "Contabilizei"),
            (accountName: "iCloud", path: "Profectum")
        ]
    )
    try expect(removed == 2)

    let iCloudFolders = try fixture.store.listFolders(accountName: "iCloud").map(\.path)
    try expect(iCloudFolders == ["Contabilizei", "Profectum"])
    let localFolders = try fixture.store.listFolders(accountName: "On My Mac").map(\.path)
    try expect(localFolders == ["Local"])
    let note = try require(fixture.store.noteById("stale-folder-note"))
    try expect(note.folderPath == "20 Projetos/Legacy")
}

runner.test("Search notes filters by folder and title metadata") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(
        id: "search-keep",
        title: "Alpha Plan",
        accountName: "iCloud",
        folderPath: "Projects",
        bodyMarkdown: "Body should not be returned"
    ))
    try fixture.store.upsertNote(makeNote(
        id: "search-title",
        title: "Beta Plan",
        accountName: "iCloud",
        folderPath: "Projects",
        bodyMarkdown: "Other body"
    ))
    try fixture.store.upsertNote(makeNote(
        id: "search-folder",
        title: "Alpha Archive",
        accountName: "iCloud",
        folderPath: "Archive",
        bodyMarkdown: "Archived body"
    ))

    let data = try service.searchNotesData([
        "folderPath": .string("Projects"),
        "titleQuery": .string("Alpha"),
        "limit": .int(10)
    ])
    let object = try require(data.objectValue)
    let notes = try require(object["notes"]?.arrayValue)
    try expect(object["count"]?.intValue == 1)
    let first = try require(notes.first?.objectValue)
    try expect(first["noteId"]?.stringValue == "search-keep")

    let json = valueToJSONString(data)
    try expect(!json.contains("Body should not be returned"))
    try expect(!json.contains("bodyMarkdown"))
    try expect(!json.contains("bodyHTML"))
}

runner.test("Bulk delete dry run reports matches without deleting") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(
        id: "dry-run-a",
        title: "Dry Run A",
        accountName: "iCloud",
        folderPath: "Cleanup",
        bodyMarkdown: "Delete candidate A"
    ))
    try fixture.store.upsertNote(makeNote(
        id: "dry-run-b",
        title: "Dry Run B",
        accountName: "iCloud",
        folderPath: "Cleanup",
        bodyMarkdown: "Delete candidate B"
    ))

    let data = try waitForAsync {
        try await service.bulkDeleteNotesData([
            "folderPath": .string("Cleanup")
        ])
    }
    let object = try require(data.objectValue)
    try expect(object["dryRun"]?.boolValue == true)
    try expect(object["matchedCount"]?.intValue == 2)
    let noteA = try fixture.store.noteById("dry-run-a")
    let noteB = try fixture.store.noteById("dry-run-b")
    try expect(noteA != nil)
    try expect(noteB != nil)

    let json = valueToJSONString(data)
    try expect(!json.contains("Delete candidate"))
    try expect(!json.contains("bodyMarkdown"))

    try expectNotesError(code: "invalid_params") {
        _ = try waitForAsync {
            try await service.bulkDeleteNotesData([
                "folderPath": .string("Cleanup"),
                "dryRun": .bool(false)
            ])
        }
    }
    let remainingA = try fixture.store.noteById("dry-run-a")
    let remainingB = try fixture.store.noteById("dry-run-b")
    try expect(remainingA != nil)
    try expect(remainingB != nil)
}

runner.test("Destructive folder and note operations require explicit confirmation") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)

    try expectNotesError(code: "invalid_params") {
        _ = try waitForAsync {
            try await service.deleteNoteData(["noteId": .string("any-note")])
        }
    }
    try expectNotesError(code: "invalid_params") {
        _ = try waitForAsync {
            try await service.deleteFolderData(["folderPath": .string("AppleNotesMCP Test")])
        }
    }
    try expectNotesError(code: "invalid_params") {
        _ = try waitForAsync {
            try await service.mergeFoldersData([
                "sourceFolderPath": .string("AppleNotesMCP Test/Source"),
                "targetFolderPath": .string("AppleNotesMCP Test/Target")
            ])
        }
    }
}

runner.test("Attachment path validation requires absolute readable regular files") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleNotesMCPAttachment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("allowed.txt")
    try "SECRET_FILE_CONTENT".write(to: fileURL, atomically: true, encoding: .utf8)

    let validated = try validatedAttachmentFileURL(rawPath: fileURL.path)
    try expect(validated.path == fileURL.standardizedFileURL.resolvingSymlinksInPath().path)

    try expectNotesError(code: "invalid_params") {
        _ = try validatedAttachmentFileURL(rawPath: "relative/allowed.txt")
    }
    try expectNotesError(code: "attachment_failed") {
        _ = try validatedAttachmentFileURL(rawPath: directory.path)
    }

    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(
        id: "attach-note",
        title: "Attach Note",
        bodyMarkdown: "Attachment target"
    ))
    let result = try waitForAsync {
        try await service.attachFileData([
            "noteId": .string("attach-note"),
            "filePath": .string(fileURL.path),
            "mode": .string("file_link_only")
        ])
    }
    let json = valueToJSONString(result.0)
    try expect(json.contains("file_link_fallback"))
    try expect(!json.contains("SECRET_FILE_CONTENT"))
}

runner.test("sqlite-vec search returns nearest chunk and enforces limit") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    try expect(fixture.store.vectorAvailable)

    try fixture.store.upsertNote(makeNote(id: "note-a", title: "A", bodyMarkdown: "Vector alpha"))
    try fixture.store.upsertNote(makeNote(id: "note-b", title: "B", bodyMarkdown: "Vector beta"))

    try fixture.store.replaceChunks(
        noteId: "note-a",
        chunks: [makeChunk(id: "chunk-a", noteId: "note-a", index: 0, text: "Vector alpha")],
        embeddings: ["chunk-a": [1, 0, 0, 0]]
    )
    try fixture.store.replaceChunks(
        noteId: "note-b",
        chunks: [makeChunk(id: "chunk-b", noteId: "note-b", index: 0, text: "Vector beta")],
        embeddings: ["chunk-b": [0, 1, 0, 0]]
    )

    let results = try fixture.store.searchVector(queryVector: [1, 0, 0, 0], limit: 1, accountName: nil, folderPath: nil)
    try expect(results.count == 1)
    try expect(results.first?.noteId == "note-a")
}

runner.test("RAG search returns sqlite-vec chunk metadata") {
    let fixture = try StoreFixture(embeddingDimension: 4, embeddingsEnabled: true)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    let query = "alpha metadata"
    let vector = try waitForAsync {
        try await HashingEmbeddingProvider(dimension: 4).embed(query)
    }

    try fixture.store.upsertNote(makeNote(
        id: "rag-note",
        title: "RAG Note",
        accountName: "iCloud",
        folderPath: "Projects",
        bodyMarkdown: "Alpha metadata note body"
    ))
    try fixture.store.replaceChunks(
        noteId: "rag-note",
        chunks: [makeChunk(id: "rag-chunk", noteId: "rag-note", index: 2, text: "Alpha metadata chunk body")],
        embeddings: ["rag-chunk": vector]
    )

    let (data, warnings) = try waitForAsync {
        try await service.searchRAGData([
            "query": .string(query),
            "limit": .int(5)
        ])
    }
    try expect(warnings.isEmpty)

    let results = try resultObjects(from: data)
    let first = try require(results.first)
    try expect(first["noteId"] as? String == "rag-note")
    try expect(first["title"] as? String == "RAG Note")
    try expect(first["snippet"] as? String == "Alpha metadata chunk body")
    try expect(first["accountName"] as? String == "iCloud")
    try expect(first["folderPath"] as? String == "Projects")
    let vectorScore = try require(first["vectorScore"] as? NSNumber).doubleValue
    let chunkIndex = try require(first["chunkIndex"] as? NSNumber).intValue
    try expect(vectorScore > 0)
    try expect(chunkIndex == 2)
}

runner.test("Hybrid search deduplicates by note and returns score components") {
    let fixture = try StoreFixture(embeddingDimension: 4, embeddingsEnabled: true)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    let query = "shared alpha"
    let vector = try waitForAsync {
        try await HashingEmbeddingProvider(dimension: 4).embed(query)
    }

    try fixture.store.upsertNote(makeNote(
        id: "hybrid-note",
        title: "Shared Alpha",
        bodyMarkdown: "Shared alpha lexical body"
    ))
    try fixture.store.replaceChunks(
        noteId: "hybrid-note",
        chunks: [
            makeChunk(id: "hybrid-chunk-0", noteId: "hybrid-note", index: 0, text: "Shared alpha chunk zero"),
            makeChunk(id: "hybrid-chunk-1", noteId: "hybrid-note", index: 1, text: "Shared alpha chunk one")
        ],
        embeddings: [
            "hybrid-chunk-0": vector,
            "hybrid-chunk-1": vector
        ]
    )

    let (data, warnings) = try waitForAsync {
        try await service.searchHybridData([
            "query": .string(query),
            "limit": .int(10)
        ])
    }
    try expect(warnings.isEmpty)

    let results = try resultObjects(from: data)
    let ids = results.compactMap { $0["noteId"] as? String }
    try expect(ids.filter { $0 == "hybrid-note" }.count == 1)

    let result = try require(results.first { $0["noteId"] as? String == "hybrid-note" })
    try expect(result["lexicalScore"] is NSNumber)
    try expect(result["vectorScore"] is NSNumber)
    try expect(result["combinedScore"] is NSNumber)
    try expect((result["rankReason"] as? String)?.isEmpty == false)
}

runner.test("Hybrid search respects account and folder filters") {
    let fixture = try StoreFixture(embeddingDimension: 4, embeddingsEnabled: true)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    let query = "filtered alpha"
    let vector = try waitForAsync {
        try await HashingEmbeddingProvider(dimension: 4).embed(query)
    }

    for note in [
        makeNote(id: "filter-keep", title: "Keep", accountName: "iCloud", folderPath: "Projects", bodyMarkdown: "Filtered alpha body"),
        makeNote(id: "filter-account", title: "Wrong Account", accountName: "On My Mac", folderPath: "Projects", bodyMarkdown: "Filtered alpha body"),
        makeNote(id: "filter-folder", title: "Wrong Folder", accountName: "iCloud", folderPath: "Archive", bodyMarkdown: "Filtered alpha body")
    ] {
        try fixture.store.upsertNote(note)
        try fixture.store.replaceChunks(
            noteId: note.id,
            chunks: [makeChunk(id: "\(note.id)-chunk", noteId: note.id, index: 0, text: "Filtered alpha chunk")],
            embeddings: ["\(note.id)-chunk": vector]
        )
    }

    let (data, warnings) = try waitForAsync {
        try await service.searchHybridData([
            "query": .string(query),
            "limit": .int(10),
            "accountName": .string("iCloud"),
            "folderPath": .string("Projects")
        ])
    }
    try expect(warnings.isEmpty)

    let results = try resultObjects(from: data)
    try expect(results.map { $0["noteId"] as? String } == ["filter-keep"])
}

runner.test("Hybrid search falls back to FTS when vector search is unavailable") {
    let fixture = try StoreFixture(
        embeddingDimension: 4,
        embeddingsEnabled: true,
        configEmbeddingDimension: 8
    )
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)

    try fixture.store.upsertNote(makeNote(
        id: "fallback-note",
        title: "Fallback Note",
        bodyMarkdown: "Fallback keyword body"
    ))

    let (data, warnings) = try waitForAsync {
        try await service.searchHybridData([
            "query": .string("fallback"),
            "limit": .int(5)
        ])
    }

    try expect(warnings.contains { $0.contains("Vector search unavailable") })
    let results = try resultObjects(from: data)
    let first = try require(results.first)
    try expect(first["noteId"] as? String == "fallback-note")
    let vectorScore = try require(first["vectorScore"] as? NSNumber).doubleValue
    try expect(vectorScore == 0)
    try expect(first["combinedScore"] is NSNumber)
    try expect(first["rankReason"] as? String == "fts_fallback_vector_unavailable")
}

runner.test("Extracted links and backlinks use only temporary SQLite data") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)

    try fixture.store.upsertNote(makeNote(id: "target", title: "Target Note", bodyMarkdown: "Target body"))
    try fixture.store.upsertNote(makeNote(
        id: "source",
        title: "Source Note",
        bodyMarkdown: "See [[Target Note]] for details."
    ))

    _ = try service.extractLinksData(["noteId": .string("source")])
    _ = try service.extractLinksData(["noteId": .string("source")])

    let target = try require(fixture.store.noteById("target"))
    let backlinks = try fixture.store.backlinks(targetNote: target)
    try expect(backlinks.count == 1)
    try expect(backlinks.first?.sourceNoteId == "source")
    try expect(backlinks.first?.targetNoteId == "target")
    try expect(backlinks.first?.linkType == "wikilink_detected")
}

runner.test("Native tag UI failure falls back to SQLite metadata") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(id: "tag-fallback", title: "Tag Fallback", bodyMarkdown: "Body"))

    let data = try waitForAsync {
        try await service.applyNativeTagsData([
            "noteId": .string("tag-fallback"),
            "tags": .array([.string("project"), .string("#reference")]),
            "experimentalNativeUI": .bool(true)
        ])
    }

    let object = try require(data.objectValue)
    let native = try require(object["experimentalNativeUI"]?.objectValue)
    try expect(native["nativeApplied"]?.boolValue == false)
    try expect(native["fallback"]?.stringValue == "sqlite_metadata")
    try expect(native["limitation"]?.stringValue?.contains("not reliably writable") == true)
    let note = try require(fixture.store.noteById("tag-fallback"))
    try expect(note.tags == ["project", "reference"])
}

runner.test("Native link UI failure falls back to SQLite link index") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)
    try fixture.store.upsertNote(makeNote(id: "source-native-fallback", title: "Source Native Fallback", bodyMarkdown: "Source"))
    try fixture.store.upsertNote(makeNote(id: "target-native-fallback", title: "Target Native Fallback", bodyMarkdown: "Target"))

    let data = try waitForAsync {
        try await service.linkNotesData([
            "sourceNoteId": .string("source-native-fallback"),
            "targetNoteId": .string("target-native-fallback"),
            "mode": .string("related_section"),
            "experimentalNativeUI": .bool(true)
        ])
    }

    let object = try require(data.objectValue)
    try expect(object["indexedOnlyFallback"]?.boolValue == true)
    let native = try require(object["experimentalNativeUI"]?.objectValue)
    try expect(native["nativeApplied"]?.boolValue == false)
    try expect(native["fallback"]?.stringValue == "sqlite_link_index")
    try expect(native["limitation"]?.stringValue?.contains("not reliably writable") == true)
    let target = try require(fixture.store.noteById("target-native-fallback"))
    let backlinks = try fixture.store.backlinks(targetNote: target)
    try expect(backlinks.count == 1)
    try expect(backlinks.first?.sourceNoteId == "source-native-fallback")
}

runner.test("Native tag UI tool requires explicit experimental opt-in") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let service = NotesService(config: fixture.config, logger: fixture.logger, store: fixture.store)

    let result = try waitForAsync {
        await service.callTool(
            name: "notes_apply_native_tags",
            arguments: [
                "title": .string("SECRET_NATIVE_TAG_NOTE"),
                "tags": .array([.string("SECRET_NATIVE_TAG")]),
                "experimentalNativeUI": .bool(false)
            ]
        )
    }

    try expect(result.1 == true)
    let log = try String(contentsOfFile: fixture.logPath, encoding: .utf8)
    try expect(log.contains("operation=notes_apply_native_tags"))
    try expect(!log.contains("SECRET_NATIVE_TAG_NOTE"))
    try expect(!log.contains("SECRET_NATIVE_TAG"))
}

runner.test("Initialize and tools/list over STDIO with temporary config") {
    let fixture = try StoreFixture(embeddingDimension: 4)
    let binaryURL = productsDirectory.appendingPathComponent("AppleNotesMCP")
    try expect(
        FileManager.default.isExecutableFile(atPath: binaryURL.path),
        "Missing executable at \(binaryURL.path)"
    )

    let process = Process()
    process.executableURL = binaryURL
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["APPLE_NOTES_MCP_CONFIG": fixture.configPath],
        uniquingKeysWith: { _, new in new }
    )

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    let stdoutCapture = PipeCapture(pipe: output)
    let stderrCapture = PipeCapture(pipe: error)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    try process.run()

    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
    ].joined(separator: "\n") + "\n"

    try input.fileHandleForWriting.write(contentsOf: require(requests.data(using: .utf8)))

    let responseDeadline = Date().addingTimeInterval(5)
    var responses: [[String: Any]] = []
    while Date() < responseDeadline {
        if let parsed = try? parseJSONLines(stdoutCapture.string()) {
            responses = parsed
            if response(id: 2, in: responses) != nil {
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    try expect(
        response(id: 1, in: responses)?["result"] != nil,
        "Missing initialize response. stdout=\(stdoutCapture.string()) stderr=\(stderrCapture.string())"
    )
    try expect(
        response(id: 2, in: responses)?["result"] != nil,
        "Missing tools/list response. stdout=\(stdoutCapture.string()) stderr=\(stderrCapture.string())"
    )

    try input.fileHandleForWriting.close()

    let exited = DispatchGroup()
    exited.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        exited.leave()
    }
    let waitResult = exited.wait(timeout: .now() + 5)
    if waitResult != .success {
        process.terminate()
        throw TestFailure(
            message: "MCP server did not exit after STDIN closed",
            file: #filePath,
            line: #line
        )
    }

    stdoutCapture.stop()
    stderrCapture.stop()
    let stderr = stderrCapture.string()
    try expect(process.terminationStatus == 0, stderr)

    let toolsResult = try require(response(id: 2, in: responses)?["result"] as? [String: Any])
    let tools = try require(toolsResult["tools"] as? [[String: Any]])
    let toolNames = Set(tools.compactMap { $0["name"] as? String })

    for requiredTool in [
        "notes_health",
        "notes_list_accounts",
        "notes_list_folders",
        "notes_create_folder",
        "notes_rename_folder",
        "notes_move_folder",
        "notes_delete_folder",
        "notes_create",
        "notes_read",
        "notes_update",
        "notes_rename_note",
        "notes_delete",
        "notes_move",
        "notes_search_notes",
        "notes_search_fts",
        "notes_search_rag",
        "notes_search_hybrid",
        "notes_sync_index",
        "notes_rebuild_search",
        "notes_attach_file",
        "notes_bulk_move_notes",
        "notes_bulk_archive_notes",
        "notes_bulk_delete_notes",
        "notes_merge_folders",
        "notes_link",
        "notes_apply_native_tags",
        "notes_backlinks",
        "notes_extract_links"
    ] {
        try expect(toolNames.contains(requiredTool), "Missing MCP tool \(requiredTool)")
    }
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ newValue: Result<T, Error>) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func waitForAsync<T: Sendable>(
    timeout: TimeInterval = 5,
    _ operation: @escaping @Sendable () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = AsyncResultBox<T>()
    Task {
        do {
            resultBox.set(.success(try await operation()))
        } catch {
            resultBox.set(.failure(error))
        }
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw TestFailure(message: "Timed out waiting for async operation", file: "\(file)", line: line)
    }
    return try require(resultBox.get(), file: file, line: line).get()
}

private func resultObjects(from value: MCPValue) throws -> [[String: Any]] {
    let data = try require(valueToJSONString(value).data(using: .utf8))
    let object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try require(object["results"] as? [[String: Any]])
}

private final class StoreFixture {
    let directory: URL
    let databasePath: String
    let logPath: String
    let configPath: String
    let config: AppConfig
    let logger: AppLogger
    let store: SQLiteStore

    init(
        embeddingDimension: Int,
        embeddingsEnabled: Bool = false,
        configEmbeddingDimension: Int? = nil,
        logLevel: String = "error"
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleNotesMCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        databasePath = directory.appendingPathComponent("index.sqlite").path
        logPath = directory.appendingPathComponent("server.log").path
        configPath = directory.appendingPathComponent("config.json").path
        let activeConfigDimension = configEmbeddingDimension ?? embeddingDimension
        config = AppConfig(
            defaultAccount: "iCloud",
            allowOnMyMac: true,
            databasePath: databasePath,
            logPath: logPath,
            logLevel: logLevel,
            embeddingsEnabled: embeddingsEnabled,
            maxEmbeddingConcurrency: 1,
            maxSyncConcurrency: 1,
            syncLockPath: directory.appendingPathComponent("sync.lock").path,
            embeddingProvider: HashingEmbeddingProvider.providerName,
            embeddingLanguage: HashingEmbeddingProvider.language,
            embeddingDimension: activeConfigDimension
        )

        let configData = try JSONEncoder().encode(config)
        try configData.write(to: URL(fileURLWithPath: configPath))

        logger = try AppLogger(path: logPath, level: logLevel)
        store = try SQLiteStore(
            path: databasePath,
            logger: logger,
            embeddingDimension: embeddingDimension,
            embeddingProvider: HashingEmbeddingProvider.providerName,
            embeddingLanguage: HashingEmbeddingProvider.language
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.lock.lock()
            self?.data.append(chunk)
            self?.lock.unlock()
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func stop() {
        handle.readabilityHandler = nil
    }
}

private func makeNote(
    id: String,
    title: String,
    accountName: String = "iCloud",
    folderPath: String = "AppleNotesMCP Automated Test",
    bodyMarkdown: String
) -> IndexedNote {
    let html = MarkdownConverter().markdownToHTML(bodyMarkdown)
    return IndexedNote(
        id: id,
        appleNoteId: nil,
        accountName: accountName,
        folderPath: folderPath,
        title: title,
        bodyHTML: html,
        bodyMarkdown: bodyMarkdown,
        bodyHash: stableHash(html),
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
        indexedAt: "2026-01-01T00:00:00Z",
        deletedAt: nil,
        tags: []
    )
}

private func makeChunk(id: String, noteId: String, index: Int, text: String) -> NoteChunk {
    NoteChunk(
        id: id,
        noteId: noteId,
        index: index,
        text: text,
        textHash: stableHash(text),
        tokenEstimate: max(1, text.split { $0.isWhitespace }.count)
    )
}

private func sqliteTableExists(path: String, tableName: String) throws -> Bool {
    try sqliteStringScalar(
        path: path,
        sql: "SELECT name FROM sqlite_master WHERE name = '\(tableName)'"
    ) == tableName
}

private func sqliteStringScalar(path: String, sql: String) throws -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw sqliteTestError(db: db)
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw sqliteTestError(db: db)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW,
          let text = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: text)
}

private func sqliteIntScalar(path: String, sql: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw sqliteTestError(db: db)
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw sqliteTestError(db: db)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(statement, 0))
}

private func sqliteTestError(db: OpaquePointer?) -> NSError {
    let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "SQLite test error"
    return NSError(domain: "AppleNotesMCPTests.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private var productsDirectory: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
}

private func parseJSONLines(_ output: String) throws -> [[String: Any]] {
    try output
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { line in
            let data = try require(line.data(using: .utf8))
            return try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
}

private func response(id: Int, in responses: [[String: Any]]) -> [String: Any]? {
    responses.first { response in
        (response["id"] as? NSNumber)?.intValue == id
    }
}

exit(runner.run())
#else
print("AppleNotesMCPTestHarness is only active in debug test builds.")
#endif
