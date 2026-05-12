import Foundation
import CSQLite
import SQLiteVecBridge

final class SQLiteStore: @unchecked Sendable {
    static let currentSchemaVersion = 2

    private let path: String
    private let logger: AppLogger
    private let embeddingProfile: EmbeddingProfile
    private let lock = NSLock()
    private var db: OpaquePointer?
    private(set) var vectorAvailable = false
    private(set) var schemaVersion = 0

    init(
        path: String,
        logger: AppLogger,
        embeddingDimension: Int,
        embeddingProvider: String = HashingEmbeddingProvider.providerName,
        embeddingLanguage: String = HashingEmbeddingProvider.language
    ) throws {
        self.path = path
        self.logger = logger
        self.embeddingProfile = EmbeddingProfile(
            provider: embeddingProvider,
            dimension: embeddingDimension,
            language: embeddingLanguage
        )
        try ensureParentDirectory(for: path)

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw sqliteError(code: "sqlite_open_failed")
        }
        if let db, AppleNotesMCPRegisterSQLiteVec(db) == SQLITE_OK {
            vectorAvailable = true
        }
        sqlite3_busy_timeout(db, 5_000)
        try configure()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func databasePath() -> String { path }

    func noteCount() throws -> Int {
        try intScalar("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL")
    }

    func lastSync() throws -> String? {
        try stringScalar("SELECT value FROM metadata WHERE key = 'last_sync_at'")
    }

    func setLastSync(_ value: String) throws {
        try execute(
            "INSERT INTO metadata(key, value) VALUES('last_sync_at', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [value]
        )
    }

    func embeddingMetadata() throws -> EmbeddingProfile? {
        lock.lock()
        defer { lock.unlock() }
        return try embeddingProfileLocked()
    }

    func staleEmbeddingCount() throws -> Int {
        try intScalar("SELECT COUNT(*) FROM chunks WHERE embedding_stale = 1")
    }

    func upsertFolder(accountName: String, path: String) throws {
        try execute(
            """
            INSERT INTO folders(id, account_name, path, created_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(account_name, path) DO NOTHING
            """,
            [UUID().uuidString, accountName, path, isoNow()]
        )
    }

    func replaceFolderCache(accountName: String?, liveFolders: [(accountName: String, path: String)]) throws -> Int {
        var liveByKey: [String: (accountName: String, path: String)] = [:]
        for folder in liveFolders {
            let path = normalizeFolderPath(folder.path)
            guard !path.isEmpty else { continue }
            if let accountName, folder.accountName != accountName { continue }
            liveByKey[folderCacheKey(accountName: folder.accountName, path: path)] = (folder.accountName, path)
        }

        var removed = 0
        try transaction {
            var sql = "SELECT id, account_name, path FROM folders"
            var args: [Any?] = []
            if let accountName {
                sql += " WHERE account_name = ?"
                args.append(accountName)
            }
            let existing = try queryLocked(sql, args) { stmt in
                (
                    id: columnString(stmt, 0) ?? "",
                    accountName: columnString(stmt, 1) ?? "",
                    path: columnString(stmt, 2) ?? ""
                )
            }
            for folder in existing {
                let key = folderCacheKey(accountName: folder.accountName, path: folder.path)
                guard liveByKey[key] == nil else { continue }
                try executeLocked("DELETE FROM folders WHERE id = ?", [folder.id])
                removed += 1
            }
            for folder in liveByKey.values {
                try executeLocked(
                    """
                    INSERT INTO folders(id, account_name, path, created_at)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(account_name, path) DO NOTHING
                    """,
                    [UUID().uuidString, folder.accountName, folder.path, isoNow()]
                )
            }
        }
        return removed
    }

    func listFolders(accountName: String?) throws -> [FolderRecord] {
        var sql = "SELECT id, account_name, path, created_at FROM folders"
        var args: [Any?] = []
        if let accountName {
            sql += " WHERE account_name = ?"
            args.append(accountName)
        }
        sql += " ORDER BY account_name, path"
        return try query(sql, args) { stmt in
            FolderRecord(
                id: columnString(stmt, 0) ?? "",
                accountName: columnString(stmt, 1) ?? "",
                path: columnString(stmt, 2) ?? "",
                createdAt: columnString(stmt, 3) ?? ""
            )
        }
    }

    func folderByPath(accountName: String, path: String) throws -> FolderRecord? {
        try query(
            """
            SELECT id, account_name, path, created_at
            FROM folders
            WHERE account_name = ? AND path = ?
            """,
            [accountName, path]
        ) { stmt in
            FolderRecord(
                id: columnString(stmt, 0) ?? "",
                accountName: columnString(stmt, 1) ?? "",
                path: columnString(stmt, 2) ?? "",
                createdAt: columnString(stmt, 3) ?? ""
            )
        }.first
    }

    func listFolderSummaries(accountName: String?) throws -> [FolderSummary] {
        let folders = try listFolders(accountName: accountName)
        let idsByAccountAndPath = Dictionary(
            uniqueKeysWithValues: folders.map { ("\($0.accountName)\u{1F}\($0.path)", $0.id) }
        )
        return try folders.map { folder in
            let parentId = parentPath(folder.path).flatMap {
                idsByAccountAndPath["\(folder.accountName)\u{1F}\($0)"]
            }
            return FolderSummary(
                id: folder.id,
                accountName: folder.accountName,
                path: folder.path,
                parentId: parentId,
                childCount: childFolderCount(accountName: folder.accountName, path: folder.path, in: folders),
                noteCount: try noteCount(accountName: folder.accountName, folderPath: folder.path),
                createdAt: folder.createdAt
            )
        }
    }

    func searchNotes(
        title: String?,
        titleQuery: String?,
        accountName: String?,
        folderPath: String?,
        limit: Int
    ) throws -> [IndexedNote] {
        var sql = """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes
            WHERE deleted_at IS NULL
            """
        var args: [Any?] = []
        if let accountName {
            sql += " AND account_name = ?"
            args.append(accountName)
        }
        if let folderPath {
            sql += " AND folder_path = ?"
            args.append(folderPath)
        }
        if let title {
            sql += " AND title = ?"
            args.append(title)
        }
        if let titleQuery {
            sql += " AND title LIKE ? COLLATE NOCASE"
            args.append("%\(titleQuery)%")
        }
        sql += " ORDER BY updated_at DESC, title LIMIT ?"
        args.append(max(1, min(limit, 500)))
        return try query(sql, args, rowToNote)
    }

    func updateFolderPath(
        accountName: String,
        oldPath: String,
        newPath: String,
        newAccountName: String? = nil
    ) throws -> Int {
        let targetAccountName = newAccountName ?? accountName
        var changedNotes = 0
        try transaction {
            let folderRows = try queryLocked(
                """
                SELECT id, path FROM folders
                WHERE account_name = ? AND (path = ? OR path LIKE ?)
                ORDER BY length(path)
                """,
                [accountName, oldPath, "\(oldPath)/%"]
            ) { stmt in
                (columnString(stmt, 0) ?? "", columnString(stmt, 1) ?? "")
            }
            for (id, path) in folderRows {
                let updatedPath = replacePathPrefix(path: path, oldPrefix: oldPath, newPrefix: newPath)
                try executeLocked(
                    "DELETE FROM folders WHERE account_name = ? AND path = ? AND id <> ?",
                    [targetAccountName, updatedPath, id]
                )
                try executeLocked(
                    "UPDATE folders SET account_name = ?, path = ? WHERE id = ?",
                    [targetAccountName, updatedPath, id]
                )
            }

            let noteRows = try queryLocked(
                """
                SELECT id, folder_path FROM notes
                WHERE deleted_at IS NULL
                  AND account_name = ?
                  AND (folder_path = ? OR folder_path LIKE ?)
                """,
                [accountName, oldPath, "\(oldPath)/%"]
            ) { stmt in
                (columnString(stmt, 0) ?? "", columnString(stmt, 1) ?? "")
            }
            for (id, path) in noteRows {
                try executeLocked(
                    "UPDATE notes SET account_name = ?, folder_path = ?, indexed_at = ? WHERE id = ?",
                    [
                        targetAccountName,
                        replacePathPrefix(path: path, oldPrefix: oldPath, newPrefix: newPath),
                        isoNow(),
                        id
                    ]
                )
                try refreshFTSForNoteLocked(noteId: id)
                changedNotes += 1
            }
        }
        return changedNotes
    }

    func updateNoteLocation(noteId: String, accountName: String, folderPath: String) throws {
        try transaction {
            try executeLocked(
                "UPDATE notes SET account_name = ?, folder_path = ?, indexed_at = ? WHERE id = ?",
                [accountName, folderPath, isoNow(), noteId]
            )
            try refreshFTSForNoteLocked(noteId: noteId)
            try executeLocked(
                """
                INSERT INTO folders(id, account_name, path, created_at)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(account_name, path) DO NOTHING
                """,
                [UUID().uuidString, accountName, folderPath, isoNow()]
            )
        }
    }

    func markFolderDeleted(accountName: String, path: String) throws -> Int {
        var deletedNotes = 0
        try transaction {
            let noteIds = try queryLocked(
                """
                SELECT id FROM notes
                WHERE deleted_at IS NULL
                  AND account_name = ?
                  AND (folder_path = ? OR folder_path LIKE ?)
                """,
                [accountName, path, "\(path)/%"]
            ) { stmt in columnString(stmt, 0) ?? "" }
            for noteId in noteIds {
                try executeLocked("UPDATE notes SET deleted_at = ? WHERE id = ?", [isoNow(), noteId])
                try executeLocked("DELETE FROM notes_fts WHERE note_id = ?", [noteId])
                try executeLocked("DELETE FROM chunks WHERE note_id = ?", [noteId])
                deletedNotes += 1
            }
            try executeLocked(
                "DELETE FROM folders WHERE account_name = ? AND (path = ? OR path LIKE ?)",
                [accountName, path, "\(path)/%"]
            )
        }
        return deletedNotes
    }

    func upsertNote(_ note: IndexedNote) throws {
        try transaction {
            let tagsJSON = jsonString(note.tags)
            try executeLocked(
                """
                INSERT INTO notes(
                    id, apple_note_id, account_name, folder_path, title,
                    body_html, body_markdown, body_hash,
                    created_at, updated_at, indexed_at, deleted_at, tags
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    apple_note_id = excluded.apple_note_id,
                    account_name = excluded.account_name,
                    folder_path = excluded.folder_path,
                    title = excluded.title,
                    body_html = excluded.body_html,
                    body_markdown = excluded.body_markdown,
                    body_hash = excluded.body_hash,
                    created_at = COALESCE(notes.created_at, excluded.created_at),
                    updated_at = excluded.updated_at,
                    indexed_at = excluded.indexed_at,
                    deleted_at = excluded.deleted_at,
                    tags = excluded.tags
                """,
                [
                    note.id, note.appleNoteId, note.accountName, note.folderPath, note.title,
                    note.bodyHTML, note.bodyMarkdown, note.bodyHash,
                    note.createdAt, note.updatedAt, note.indexedAt, note.deletedAt, tagsJSON
                ]
            )

            if let appleNoteId = note.appleNoteId {
                try executeLocked(
                    """
                    UPDATE notes SET
                        account_name = ?, folder_path = ?, title = ?,
                        body_html = ?, body_markdown = ?, body_hash = ?,
                        updated_at = ?, indexed_at = ?, deleted_at = ?, tags = ?
                    WHERE apple_note_id = ? AND id <> ?
                    """,
                    [
                        note.accountName, note.folderPath, note.title,
                        note.bodyHTML, note.bodyMarkdown, note.bodyHash,
                        note.updatedAt, note.indexedAt, note.deletedAt, tagsJSON,
                        appleNoteId, note.id
                    ]
                )
            }

            try executeLocked("DELETE FROM notes_fts WHERE note_id = ?", [note.id])
            if note.deletedAt == nil {
                try executeLocked(
                    """
                    INSERT INTO notes_fts(note_id, title, body_markdown, folder_path, tags)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        note.id,
                        note.title,
                        note.bodyMarkdown ?? "",
                        note.folderPath ?? "",
                        note.tags.joined(separator: " ")
                    ]
                )
            }

            if let account = note.accountName, let folder = note.folderPath, !folder.isEmpty {
                try executeLocked(
                    """
                    INSERT INTO folders(id, account_name, path, created_at)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(account_name, path) DO NOTHING
                    """,
                    [UUID().uuidString, account, folder, isoNow()]
                )
            }
        }
    }

    func replaceChunks(noteId: String, chunks: [NoteChunk], embeddings: [String: [Float]]) throws {
        try transaction {
            if vectorAvailable {
                try executeLocked(
                    "DELETE FROM vec_chunks WHERE chunk_id IN (SELECT id FROM chunks WHERE note_id = ?)",
                    [noteId]
                )
            }
            try executeLocked("DELETE FROM chunks WHERE note_id = ?", [noteId])
            for chunk in chunks {
                let vector = embeddings[chunk.id]
                try executeLocked(
                    """
                    INSERT INTO chunks(
                        id, note_id, chunk_index, text, text_hash, token_estimate,
                        embedding_blob, embedding_dimension, embedding_stale, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        chunk.id,
                        chunk.noteId,
                        chunk.index,
                        chunk.text,
                        chunk.textHash,
                        chunk.tokenEstimate,
                        vector.map(vectorToBlob),
                        vector?.count,
                        0,
                        isoNow(),
                        isoNow()
                    ]
                )
                if vectorAvailable, let vector {
                    try executeLocked(
                        "INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)",
                        [chunk.id, vectorToBlob(vector)]
                    )
                }
            }
        }
    }

    func noteById(_ id: String) throws -> IndexedNote? {
        try query(
            """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes WHERE id = ? AND deleted_at IS NULL
            """,
            [id],
            rowToNote
        ).first
    }

    func noteByAppleId(_ appleId: String) throws -> IndexedNote? {
        try query(
            """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes WHERE apple_note_id = ? AND deleted_at IS NULL
            """,
            [appleId],
            rowToNote
        ).first
    }

    func notesByTitle(_ title: String) throws -> [IndexedNote] {
        try query(
            """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes WHERE title = ? AND deleted_at IS NULL
            ORDER BY indexed_at DESC
            """,
            [title],
            rowToNote
        )
    }

    func allNotes() throws -> [IndexedNote] {
        try query(
            """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes WHERE deleted_at IS NULL
            ORDER BY updated_at DESC, title
            """,
            [],
            rowToNote
        )
    }

    func markDeleted(noteId: String) throws {
        try transaction {
            try executeLocked("UPDATE notes SET deleted_at = ? WHERE id = ?", [isoNow(), noteId])
            try executeLocked("DELETE FROM notes_fts WHERE note_id = ?", [noteId])
            try executeLocked("DELETE FROM chunks WHERE note_id = ?", [noteId])
        }
    }

    func markMissingAsDeleted(seenAppleIds: Set<String>, accountName: String?, folderPath: String?) throws -> Int {
        let existing = try query(
            "SELECT id, apple_note_id FROM notes WHERE deleted_at IS NULL",
            []
        ) { stmt -> (String, String?) in
            (columnString(stmt, 0) ?? "", columnString(stmt, 1))
        }

        var count = 0
        try transaction {
            for (id, appleId) in existing {
                guard let appleId, !seenAppleIds.contains(appleId) else { continue }
                if let accountName {
                    let note = try noteByIdLocked(id)
                    if note?.accountName != accountName { continue }
                }
                if let folderPath {
                    let note = try noteByIdLocked(id)
                    if note?.folderPath != folderPath { continue }
                }
                try executeLocked("UPDATE notes SET deleted_at = ? WHERE id = ?", [isoNow(), id])
                try executeLocked("DELETE FROM notes_fts WHERE note_id = ?", [id])
                count += 1
            }
        }
        return count
    }

    func searchFTS(query rawQuery: String, limit: Int, accountName: String?, folderPath: String?) throws -> [SearchResult] {
        let limit = max(1, min(limit, 500))
        var sql = """
            SELECT bm25(notes_fts) AS score, n.title,
                   snippet(notes_fts, 2, '[', ']', '...', 18) AS snippet,
                   n.id, n.account_name, n.folder_path
            FROM notes_fts
            JOIN notes n ON n.id = notes_fts.note_id
            WHERE notes_fts MATCH ? AND n.deleted_at IS NULL
            """
        var args: [Any?] = [ftsQuery(rawQuery)]
        if let accountName {
            sql += " AND n.account_name = ?"
            args.append(accountName)
        }
        if let folderPath {
            sql += " AND n.folder_path = ?"
            args.append(folderPath)
        }
        sql += " ORDER BY score LIMIT ?"
        args.append(limit)

        return try query(sql, args) { stmt in
            SearchResult(
                score: sqlite3_column_double(stmt, 0),
                title: columnString(stmt, 1) ?? "",
                snippet: columnString(stmt, 2) ?? "",
                noteId: columnString(stmt, 3) ?? "",
                accountName: columnString(stmt, 4),
                folderPath: columnString(stmt, 5)
            )
        }
    }

    func searchVector(queryVector: [Float], limit: Int, accountName: String?, folderPath: String?) throws -> [SearchResult] {
        guard vectorAvailable else {
            throw NotesError.typed(
                code: "vector_search_unavailable",
                message: "sqlite-vec vector search is unavailable."
            )
        }
        do {
            return try searchSQLiteVec(
                queryVector: queryVector,
                limit: limit,
                accountName: accountName,
                folderPath: folderPath
            )
        } catch let error as NotesError {
            logger.error("sqlite_vec_search_failed", fields: ["code": error.code])
            throw NotesError.typed(
                code: "vector_search_unavailable",
                message: "sqlite-vec vector search failed.",
                details: ["reason": error.message]
            )
        } catch {
            logger.error("sqlite_vec_search_failed", fields: ["code": "internal_error"])
            throw NotesError.typed(
                code: "vector_search_unavailable",
                message: "sqlite-vec vector search failed.",
                details: ["reason": error.localizedDescription]
            )
        }
    }

    private func searchSQLiteVec(queryVector: [Float], limit: Int, accountName: String?, folderPath: String?) throws -> [SearchResult] {
        let limit = max(1, min(limit, 500))
        var sql = """
            SELECT v.distance, c.text, n.id, n.title, n.account_name, n.folder_path, c.chunk_index
            FROM vec_chunks v
            JOIN chunks c ON c.id = v.chunk_id
            JOIN notes n ON n.id = c.note_id
            WHERE v.embedding MATCH ? AND k = ? AND c.embedding_stale = 0 AND n.deleted_at IS NULL
            """
        var args: [Any?] = [vectorToBlob(queryVector), limit]
        if let accountName {
            sql += " AND n.account_name = ?"
            args.append(accountName)
        }
        if let folderPath {
            sql += " AND n.folder_path = ?"
            args.append(folderPath)
        }
        sql += " ORDER BY v.distance LIMIT ?"
        args.append(limit)

        let rows = try query(sql, args) { stmt in
            let distance = sqlite3_column_double(stmt, 0)
            let text = columnString(stmt, 1) ?? ""
            let vectorScore = 1 / (1 + distance)
            return SearchResult(
                score: vectorScore,
                title: columnString(stmt, 3) ?? "",
                snippet: String(text.prefix(240)),
                noteId: columnString(stmt, 2) ?? "",
                accountName: columnString(stmt, 4),
                folderPath: columnString(stmt, 5),
                vectorScore: vectorScore,
                chunkIndex: Int(sqlite3_column_int64(stmt, 6))
            )
        }
        return rows
    }

    func rebuildFTS() throws -> Int {
        var count = 0
        let notes = try allNotes()
        try transaction {
            try executeLocked("DELETE FROM notes_fts", [])
            for note in notes {
                try executeLocked(
                    """
                    INSERT INTO notes_fts(note_id, title, body_markdown, folder_path, tags)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        note.id,
                        note.title,
                        note.bodyMarkdown ?? "",
                        note.folderPath ?? "",
                        note.tags.joined(separator: " ")
                    ]
                )
                count += 1
            }
        }
        return count
    }

    func insertAttachment(_ attachment: AttachmentRecord) throws {
        try execute(
            """
            INSERT INTO attachments(
                id, note_id, file_path, file_url, filename, mime_type,
                size_bytes, attached_as, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                attachment.id, attachment.noteId, attachment.filePath, attachment.fileURL,
                attachment.filename, attachment.mimeType, attachment.sizeBytes,
                attachment.attachedAs, attachment.createdAt
            ]
        )
    }

    func insertLink(_ link: LinkRecord) throws {
        try execute(
            """
            INSERT INTO links(
                id, source_note_id, target_note_id, target_title, link_text, link_type, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                link.id, link.sourceNoteId, link.targetNoteId, link.targetTitle,
                link.linkText, link.linkType, link.createdAt
            ]
        )
    }

    func replaceDetectedLinks(sourceNoteId: String, links: [LinkRecord]) throws {
        try transaction {
            try executeLocked(
                "DELETE FROM links WHERE source_note_id = ? AND link_type = 'wikilink_detected'",
                [sourceNoteId]
            )
            for link in links {
                try executeLocked(
                    """
                    INSERT INTO links(
                        id, source_note_id, target_note_id, target_title, link_text, link_type, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        link.id, link.sourceNoteId, link.targetNoteId, link.targetTitle,
                        link.linkText, link.linkType, link.createdAt
                    ]
                )
            }
        }
    }

    func backlinks(targetNote: IndexedNote) throws -> [LinkRecord] {
        try query(
            """
            SELECT id, source_note_id, target_note_id, target_title, link_text, link_type, created_at
            FROM links
            WHERE target_note_id = ? OR target_title = ?
            ORDER BY created_at DESC
            """,
            [targetNote.id, targetNote.title],
            rowToLink
        )
    }

    func links(sourceNoteId: String) throws -> [LinkRecord] {
        try query(
            """
            SELECT id, source_note_id, target_note_id, target_title, link_text, link_type, created_at
            FROM links
            WHERE source_note_id = ?
            ORDER BY created_at DESC
            """,
            [sourceNoteId],
            rowToLink
        )
    }

    func configSummary(
        defaultAccount: String,
        embeddingsEnabled: Bool,
        embeddingProvider: String,
        embeddingDimension: Int,
        embeddingLanguage: String,
        embeddingWarnings: [String]
    ) -> MCPValue {
        let metadata = (try? embeddingMetadata()) ?? embeddingProfile
        let staleCount = (try? staleEmbeddingCount()) ?? 0
        return .object([
            "databasePath": .string(path),
            "defaultAccount": .string(defaultAccount),
            "embeddingsEnabled": .bool(embeddingsEnabled),
            "schemaVersion": .int(schemaVersion),
            "embeddingProvider": .string(embeddingProvider),
            "embeddingDimension": .int(embeddingDimension),
            "embeddingLanguage": .string(embeddingLanguage),
            "embeddingWarnings": .array(embeddingWarnings.map { .string($0) }),
            "embeddingMetadata": .object([
                "provider": .string(metadata.provider),
                "dimension": .int(metadata.dimension),
                "language": .string(metadata.language)
            ]),
            "staleEmbeddingCount": .int(staleCount),
            "vectorSearchAvailable": .bool(vectorAvailable)
        ])
    }

    private func noteCount(accountName: String, folderPath: String) throws -> Int {
        try query(
            """
            SELECT COUNT(*)
            FROM notes
            WHERE deleted_at IS NULL AND account_name = ? AND folder_path = ?
            """,
            [accountName, folderPath]
        ) { stmt in Int(sqlite3_column_int64(stmt, 0)) }.first ?? 0
    }

    private func childFolderCount(accountName: String, path: String, in folders: [FolderRecord]) -> Int {
        folders.filter { folder in
            folder.accountName == accountName && parentPath(folder.path) == path
        }.count
    }

    private func folderCacheKey(accountName: String, path: String) -> String {
        "\(accountName)\u{1F}\(path)"
    }

    private func parentPath(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private func replacePathPrefix(path: String, oldPrefix: String, newPrefix: String) -> String {
        guard path != oldPrefix else { return newPrefix }
        guard path.hasPrefix(oldPrefix + "/") else { return path }
        return newPrefix + String(path.dropFirst(oldPrefix.count))
    }

    private func refreshFTSForNoteLocked(noteId: String) throws {
        try executeLocked("DELETE FROM notes_fts WHERE note_id = ?", [noteId])
        guard let note = try noteByIdLocked(noteId) else { return }
        try executeLocked(
            """
            INSERT INTO notes_fts(note_id, title, body_markdown, folder_path, tags)
            VALUES (?, ?, ?, ?, ?)
            """,
            [
                note.id,
                note.title,
                note.bodyMarkdown ?? "",
                note.folderPath ?? "",
                note.tags.joined(separator: " ")
            ]
        )
    }

    private func configure() throws {
        try execute("PRAGMA journal_mode = WAL", [])
        try execute("PRAGMA synchronous = NORMAL", [])
        try execute("PRAGMA foreign_keys = ON", [])
        try execute("PRAGMA temp_store = MEMORY", [])
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata(
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """,
            []
        )

        let storedVersion = try schemaVersionFromMetadata()
        let migrations: [(version: Int, body: () throws -> Void)] = [
            (1, { try self.migrationCreateInitialSchema() }),
            (2, { try self.migrationAddEmbeddingMetadataSupport() })
        ]

        for migration in migrations where storedVersion < migration.version {
            try runMigration(version: migration.version, migration.body)
        }

        try reconcileEmbeddingMetadata()
        schemaVersion = try schemaVersionFromMetadata()
    }

    private func runMigration(version: Int, _ body: () throws -> Void) throws {
        try transaction {
            try body()
            try setMetadataLocked(key: "schema_version", value: "\(version)")
        }
    }

    private func migrationCreateInitialSchema() throws {
        try executeLocked(
            """
            CREATE TABLE IF NOT EXISTS notes(
                id TEXT PRIMARY KEY,
                apple_note_id TEXT UNIQUE,
                account_name TEXT,
                folder_path TEXT,
                title TEXT NOT NULL,
                body_html TEXT,
                body_markdown TEXT,
                body_hash TEXT,
                created_at TEXT,
                updated_at TEXT,
                indexed_at TEXT,
                deleted_at TEXT,
                tags TEXT
            )
            """, []
        )
        try executeLocked(
            """
            CREATE TABLE IF NOT EXISTS folders(
                id TEXT PRIMARY KEY,
                account_name TEXT,
                path TEXT,
                created_at TEXT,
                UNIQUE(account_name, path)
            )
            """, []
        )
        try executeLocked(
            """
            CREATE TABLE IF NOT EXISTS attachments(
                id TEXT PRIMARY KEY,
                note_id TEXT,
                file_path TEXT,
                file_url TEXT,
                filename TEXT,
                mime_type TEXT,
                size_bytes INTEGER,
                attached_as TEXT,
                created_at TEXT,
                FOREIGN KEY(note_id) REFERENCES notes(id) ON DELETE CASCADE
            )
            """, []
        )
        try executeLocked(
            """
            CREATE TABLE IF NOT EXISTS links(
                id TEXT PRIMARY KEY,
                source_note_id TEXT,
                target_note_id TEXT,
                target_title TEXT,
                link_text TEXT,
                link_type TEXT,
                created_at TEXT,
                FOREIGN KEY(source_note_id) REFERENCES notes(id) ON DELETE CASCADE,
                FOREIGN KEY(target_note_id) REFERENCES notes(id) ON DELETE SET NULL
            )
            """, []
        )
        try executeLocked(
            """
            CREATE TABLE IF NOT EXISTS chunks(
                id TEXT PRIMARY KEY,
                note_id TEXT,
                chunk_index INTEGER,
                text TEXT,
                text_hash TEXT,
                token_estimate INTEGER,
                embedding_blob BLOB,
                embedding_dimension INTEGER,
                created_at TEXT,
                updated_at TEXT,
                FOREIGN KEY(note_id) REFERENCES notes(id) ON DELETE CASCADE
            )
            """, []
        )
        try executeLocked(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                note_id UNINDEXED,
                title,
                body_markdown,
                folder_path,
                tags,
                tokenize = 'unicode61'
            )
            """, []
        )
        try createVectorTableIfAvailableLocked()
    }

    private func migrationAddEmbeddingMetadataSupport() throws {
        if try !columnExistsLocked(table: "chunks", column: "embedding_stale") {
            try executeLocked(
                "ALTER TABLE chunks ADD COLUMN embedding_stale INTEGER NOT NULL DEFAULT 0",
                []
            )
        }
    }

    private func reconcileEmbeddingMetadata() throws {
        try transaction {
            let storedProfile = try embeddingProfileLocked()
            let hasIncompatibleDimension = try hasIncompatibleEmbeddingDimensionsLocked()
            let hasIncompatibleVectorTable = try hasIncompatibleVectorTableLocked()
            let shouldMarkStale = hasIncompatibleDimension
                || hasIncompatibleVectorTable
                || (storedProfile != nil && storedProfile != embeddingProfile)

            if shouldMarkStale {
                try markVectorsStaleAndPrepareRebuildLocked()
            } else {
                try createVectorTableIfAvailableLocked()
            }

            try setMetadataLocked(key: "embedding_provider", value: embeddingProfile.provider)
            try setMetadataLocked(key: "embedding_dimension", value: "\(embeddingProfile.dimension)")
            try setMetadataLocked(key: "embedding_language", value: embeddingProfile.language)
        }
    }

    private func markVectorsStaleAndPrepareRebuildLocked() throws {
        try executeLocked(
            "UPDATE chunks SET embedding_stale = 1 WHERE embedding_blob IS NOT NULL",
            []
        )
        guard vectorAvailable else { return }
        do {
            try executeLocked("DROP TABLE IF EXISTS vec_chunks", [])
            try createVectorTableLocked()
        } catch {
            vectorAvailable = false
            logger.info("sqlite_vec_unavailable", fields: [
                "code": "sqlite_vec_unavailable",
                "provider": embeddingProfile.provider,
                "dimension": "\(embeddingProfile.dimension)"
            ])
        }
    }

    private func createVectorTableIfAvailableLocked() throws {
        guard vectorAvailable else { return }
        do {
            try createVectorTableLocked()
        } catch {
            vectorAvailable = false
            logger.info("sqlite_vec_unavailable", fields: [
                "code": "sqlite_vec_unavailable",
                "provider": embeddingProfile.provider,
                "dimension": "\(embeddingProfile.dimension)"
            ])
        }
    }

    private func createVectorTableLocked() throws {
        try executeLocked(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
                chunk_id TEXT PRIMARY KEY,
                embedding FLOAT[\(embeddingProfile.dimension)]
            )
            """,
            []
        )
    }

    private func schemaVersionFromMetadata() throws -> Int {
        Int(try metadataValue(key: "schema_version") ?? "") ?? 0
    }

    private func metadataValue(key: String) throws -> String? {
        try query(
            "SELECT value FROM metadata WHERE key = ?",
            [key]
        ) { stmt in
            columnString(stmt, 0)
        }.first ?? nil
    }

    private func metadataValueLocked(key: String) throws -> String? {
        try queryLocked(
            "SELECT value FROM metadata WHERE key = ?",
            [key]
        ) { stmt in
            columnString(stmt, 0)
        }.first ?? nil
    }

    private func setMetadataLocked(key: String, value: String) throws {
        try executeLocked(
            """
            INSERT INTO metadata(key, value)
            VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [key, value]
        )
    }

    private func embeddingProfileLocked() throws -> EmbeddingProfile? {
        guard let provider = try metadataValueLocked(key: "embedding_provider"),
              let dimensionText = try metadataValueLocked(key: "embedding_dimension"),
              let dimension = Int(dimensionText),
              let language = try metadataValueLocked(key: "embedding_language")
        else {
            return nil
        }
        return EmbeddingProfile(provider: provider, dimension: dimension, language: language)
    }

    private func hasIncompatibleEmbeddingDimensionsLocked() throws -> Bool {
        let count = try queryLocked(
            """
            SELECT COUNT(*)
            FROM chunks
            WHERE embedding_blob IS NOT NULL
              AND embedding_dimension IS NOT NULL
              AND embedding_dimension <> ?
            """,
            [embeddingProfile.dimension]
        ) { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }.first ?? 0
        return count > 0
    }

    private func hasIncompatibleVectorTableLocked() throws -> Bool {
        guard vectorAvailable else { return false }
        let sql = try queryLocked(
            "SELECT sql FROM sqlite_master WHERE name = 'vec_chunks'",
            []
        ) { stmt in
            columnString(stmt, 0)
        }.first ?? nil
        guard let sql else { return false }
        return !sql.contains("FLOAT[\(embeddingProfile.dimension)]")
    }

    private func columnExistsLocked(table: String, column: String) throws -> Bool {
        let rows = try queryLocked("PRAGMA table_info(\(table))", []) { stmt in
            columnString(stmt, 1)
        }
        return rows.contains(column)
    }

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked("BEGIN IMMEDIATE", [])
        do {
            try body()
            try executeLocked("COMMIT", [])
        } catch {
            try? executeLocked("ROLLBACK", [])
            throw error
        }
    }

    private func execute(_ sql: String, _ args: [Any?]) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked(sql, args)
    }

    private func executeLocked(_ sql: String, _ args: [Any?]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw sqliteError()
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ row: (OpaquePointer?) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return try queryLocked(sql, args, row)
    }

    private func queryLocked<T>(
        _ sql: String,
        _ args: [Any?],
        _ row: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(stmt) }
        try bind(args, to: stmt)

        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                results.append(try row(stmt))
            } else if rc == SQLITE_DONE {
                return results
            } else {
                throw sqliteError()
            }
        }
    }

    private func intScalar(_ sql: String) throws -> Int {
        try query(sql, []) { stmt in Int(sqlite3_column_int64(stmt, 0)) }.first ?? 0
    }

    private func stringScalar(_ sql: String) throws -> String? {
        try query(sql, []) { stmt in columnString(stmt, 0) }.first ?? nil
    }

    private func bind(_ args: [Any?], to stmt: OpaquePointer?) throws {
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch arg {
            case nil:
                rc = sqlite3_bind_null(stmt, position)
            case let value as String:
                rc = sqlite3_bind_text(stmt, position, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                rc = sqlite3_bind_int64(stmt, position, sqlite3_int64(value))
            case let value as Int64:
                rc = sqlite3_bind_int64(stmt, position, sqlite3_int64(value))
            case let value as Double:
                rc = sqlite3_bind_double(stmt, position, value)
            case let value as Data:
                rc = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, position, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
                }
            case let value as Bool:
                rc = sqlite3_bind_int(stmt, position, value ? 1 : 0)
            default:
                rc = sqlite3_bind_text(stmt, position, "\(String(describing: arg))", -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func rowToNote(_ stmt: OpaquePointer?) -> IndexedNote {
        IndexedNote(
            id: columnString(stmt, 0) ?? "",
            appleNoteId: columnString(stmt, 1),
            accountName: columnString(stmt, 2),
            folderPath: columnString(stmt, 3),
            title: columnString(stmt, 4) ?? "",
            bodyHTML: columnString(stmt, 5),
            bodyMarkdown: columnString(stmt, 6),
            bodyHash: columnString(stmt, 7),
            createdAt: columnString(stmt, 8),
            updatedAt: columnString(stmt, 9),
            indexedAt: columnString(stmt, 10),
            deletedAt: columnString(stmt, 11),
            tags: parseStringArray(columnString(stmt, 12))
        )
    }

    private func rowToLink(_ stmt: OpaquePointer?) -> LinkRecord {
        LinkRecord(
            id: columnString(stmt, 0) ?? "",
            sourceNoteId: columnString(stmt, 1) ?? "",
            targetNoteId: columnString(stmt, 2),
            targetTitle: columnString(stmt, 3),
            linkText: columnString(stmt, 4),
            linkType: columnString(stmt, 5) ?? "",
            createdAt: columnString(stmt, 6) ?? ""
        )
    }

    private func noteByIdLocked(_ id: String) throws -> IndexedNote? {
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, apple_note_id, account_name, folder_path, title, body_html,
                   body_markdown, body_hash, created_at, updated_at, indexed_at,
                   deleted_at, tags
            FROM notes WHERE id = ? AND deleted_at IS NULL
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(stmt) }
        try bind([id], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToNote(stmt)
    }

    private func sqliteError(code: String = "sqlite_error") -> NotesError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
            ?? "SQLite error"
        let mapped = message.lowercased().contains("busy") ? "sqlite_busy" : code
        return NotesError.typed(code: mapped, message: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

private func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
    let count = Int(sqlite3_column_bytes(stmt, index))
    return Data(bytes: bytes, count: count)
}

private func jsonString(_ strings: [String]) -> String {
    guard let data = try? JSONEncoder().encode(strings),
          let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
}

private func parseStringArray(_ text: String?) -> [String] {
    guard let text, let data = text.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return decoded
}

private func ftsQuery(_ raw: String) -> String {
    let tokens = raw
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return "\"\"" }
    return tokens.map { "\($0)*" }.joined(separator: " OR ")
}
