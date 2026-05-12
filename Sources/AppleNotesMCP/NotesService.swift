import Foundation

final class NotesService: @unchecked Sendable {
    let config: AppConfig
    let logger: AppLogger
    let store: SQLiteStore
    let jxa: JXAExecutor
    let markdown = MarkdownConverter()
    let chunker = Chunker()
    let embeddings: EmbeddingService

    init(config: AppConfig, logger: AppLogger, store: SQLiteStore) {
        self.config = config
        self.logger = logger
        self.store = store
        self.jxa = JXAExecutor(logger: logger)
        self.embeddings = EmbeddingService(config: config)
    }

    func health() async -> MCPValue {
        var permissions = "unknown"
        do {
            _ = try await listAccountsData()
            permissions = "apple_notes_automation_available"
        } catch let error as NotesError {
            permissions = error.code
        } catch {
            permissions = "apple_notes_automation_unknown"
        }

        return await healthValue(permissions: permissions)
    }

    func healthValue(permissions: String) async -> MCPValue {
        let count = (try? store.noteCount()) ?? 0
        let lastSync = (try? store.lastSync()) ?? nil
        let metadata = (try? store.embeddingMetadata()) ?? config.embeddingProfile
        let staleEmbeddingCount = (try? store.staleEmbeddingCount()) ?? 0
        return .object([
            "status": .string("ok"),
            "version": .string(AppConfig.version),
            "swiftVersionTarget": .string(AppConfig.swiftVersionTarget),
            "databasePath": .string(config.databasePath),
            "logLevel": .string(config.logLevel),
            "logPath": .string(config.logPath),
            "defaultAccount": .string(config.defaultAccount),
            "embeddingsEnabled": .bool(config.embeddingsEnabled),
            "embeddingProvider": .string(await embeddings.providerName()),
            "embeddingLanguage": .string(config.embeddingLanguage),
            "embeddingDimension": .int(config.embeddingDimension),
            "embeddingWarnings": .array(config.embeddingWarnings.map { .string($0) }),
            "schemaVersion": .int(store.schemaVersion),
            "embeddingMetadata": .object([
                "provider": .string(metadata.provider),
                "dimension": .int(metadata.dimension),
                "language": .string(metadata.language),
                "staleEmbeddingCount": .int(staleEmbeddingCount)
            ]),
            "vectorSearchAvailable": .bool(store.vectorAvailable),
            "indexedNoteCount": .int(count),
            "lastSync": lastSync.map(MCPValue.string) ?? .null,
            "permissions": .string(permissions),
            "limitations": .array(knownLimitations.map { .string($0) })
        ])
    }

    func callTool(name: String, arguments: [String: MCPValue]) async -> (MCPValue, Bool) {
        let started = Date()
        do {
            let data: MCPValue
            var warnings: [String] = []
            switch name {
            case "notes_health":
                data = await health()
            case "notes_list_accounts":
                data = try await listAccountsData()
            case "notes_list_folders":
                data = try await listFoldersData(accountName: arguments.string("accountName"))
            case "notes_create_folder":
                data = try await createFolderData(arguments)
            case "notes_rename_folder":
                data = try await renameFolderData(arguments)
            case "notes_move_folder":
                data = try await moveFolderData(arguments)
            case "notes_delete_folder":
                data = try await deleteFolderData(arguments)
            case "notes_create":
                data = try await createNoteData(arguments)
            case "notes_read":
                let result = try await readNoteData(arguments)
                data = result.0
                warnings = result.1
            case "notes_update":
                data = try await updateNoteData(arguments)
            case "notes_rename_note":
                data = try await renameNoteData(arguments)
            case "notes_delete":
                data = try await deleteNoteData(arguments)
            case "notes_move":
                data = try await moveNoteData(arguments)
            case "notes_search_notes":
                data = try searchNotesData(arguments)
            case "notes_search_fts":
                data = try searchFTSData(arguments)
            case "notes_search_rag":
                let result = try await searchRAGData(arguments)
                data = result.0
                warnings = result.1
            case "notes_search_hybrid":
                let result = try await searchHybridData(arguments)
                data = result.0
                warnings = result.1
            case "notes_sync_index":
                data = try await syncIndexData(arguments)
            case "notes_rebuild_search":
                let result = try await rebuildSearchData(arguments)
                data = result.0
                warnings = result.1
            case "notes_attach_file":
                let result = try await attachFileData(arguments)
                data = result.0
                warnings = result.1
            case "notes_bulk_move_notes":
                data = try await bulkMoveNotesData(arguments)
            case "notes_bulk_archive_notes":
                data = try await bulkArchiveNotesData(arguments)
            case "notes_bulk_delete_notes":
                data = try await bulkDeleteNotesData(arguments)
            case "notes_merge_folders":
                data = try await mergeFoldersData(arguments)
            case "notes_link":
                data = try await linkNotesData(arguments)
            case "notes_backlinks":
                data = try backlinksData(arguments)
            case "notes_extract_links":
                data = try extractLinksData(arguments)
            default:
                logger.error(
                    name,
                    fields: safeToolLogFields(
                        arguments: arguments,
                        durationMS: durationMS(since: started),
                        code: "unknown_tool"
                    )
                )
                return (errorValue(code: "unknown_tool", message: "Unknown tool: \(name)"), true)
            }
            logger.info(
                name,
                fields: safeToolLogFields(
                    arguments: arguments,
                    data: data,
                    durationMS: durationMS(since: started)
                )
            )
            return (okValue(data, warnings: warnings), false)
        } catch let error as NotesError {
            logger.error(
                name,
                fields: safeToolLogFields(
                    arguments: arguments,
                    durationMS: durationMS(since: started),
                    code: error.code
                )
            )
            return (errorValue(code: error.code, message: error.message, details: error.details), true)
        } catch {
            logger.error(
                name,
                fields: safeToolLogFields(
                    arguments: arguments,
                    durationMS: durationMS(since: started),
                    code: "internal_error"
                )
            )
            return (errorValue(code: "internal_error", message: error.localizedDescription), true)
        }
    }

    func listAccountsData() async throws -> MCPValue {
        try await jxa.run(
            operation: "notes_list_accounts",
            scriptBody: Self.scriptListAccounts,
            input: .object([:])
        )
    }

    func listFoldersData(accountName: String?) async throws -> MCPValue {
        let data = try await jxa.run(
            operation: "notes_list_folders",
            scriptBody: Self.scriptListFolders,
            input: .object(["accountName": accountName.map(MCPValue.string) ?? .null])
        )
        var liveCounts: [String: (childCount: Int, noteCount: Int)] = [:]
        var liveFolders: [(accountName: String, path: String)] = []
        if let folders = data.objectValue?["folders"]?.arrayValue {
            for item in folders {
                guard let object = item.objectValue,
                      let account = object["accountName"]?.stringValue,
                      let path = object["path"]?.stringValue
                else { continue }
                liveFolders.append((accountName: account, path: path))
                liveCounts["\(account)\u{1F}\(path)"] = (
                    object["childCount"]?.intValue ?? 0,
                    object["noteCount"]?.intValue ?? 0
                )
            }
        }
        _ = try store.replaceFolderCache(accountName: accountName, liveFolders: liveFolders)
        let summaries = try store.listFolderSummaries(accountName: accountName)
        let warnings = data.objectValue?["warnings"]?.arrayValue ?? []
        return folderSummariesValue(summaries, liveCounts: liveCounts, warnings: warnings)
    }

    func createFolderData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let account = args.string("accountName") ?? config.defaultAccount
        let folderPath = try requiredFolderPath(args.requiredString("folderPath"))
        let data = try await jxa.run(
            operation: "notes_create_folder",
            scriptBody: Self.scriptCreateFolder,
            input: .object([
                "accountName": .string(account),
                "folderPath": .string(folderPath)
            ])
        )
        try store.upsertFolder(accountName: account, path: data.objectValue?["folderPath"]?.stringValue ?? folderPath)
        return data
    }

    func createNoteData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let account = args.string("accountName") ?? config.defaultAccount
        let folderPath = args.string("folderPath")
            .map(normalizeFolderPath)
            .flatMap { $0.isEmpty ? nil : $0 }
        let title = try args.requiredString("title")
        let bodyMarkdown = try args.requiredString("bodyMarkdown")
        let tags = args["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let bodyHTML = markdown.markdownToHTML(bodyMarkdown)
        let data = try await jxa.run(
            operation: "notes_create",
            scriptBody: Self.scriptCreateNote,
            input: .object([
                "accountName": .string(account),
                "folderPath": folderPath.map(MCPValue.string) ?? .null,
                "title": .string(title),
                "bodyHTML": .string(bodyHTML)
            ])
        )

        let actualBodyHTML = data.objectValue?["bodyHTML"]?.stringValue ?? bodyHTML
        let actualBodyMarkdown = markdown.htmlToMarkdown(actualBodyHTML)
        let note = indexedNote(
            data: data,
            fallbackTitle: title,
            fallbackAccount: account,
            fallbackFolder: folderPath,
            bodyHTML: actualBodyHTML,
            bodyMarkdown: actualBodyMarkdown,
            tags: tags
        )
        try await index(note, includeEmbeddings: config.embeddingsEnabled)

        return .object([
            "noteId": .string(note.id),
            "appleNoteId": note.appleNoteId.map(MCPValue.string) ?? .null,
            "title": .string(note.title),
            "accountName": note.accountName.map(MCPValue.string) ?? .null,
            "folderPath": note.folderPath.map(MCPValue.string) ?? .null,
            "indexed": .bool(true)
        ])
    }

    func readNoteData(_ args: [String: MCPValue]) async throws -> (MCPValue, [String]) {
        let note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        var warnings: [String] = []
        var current = note

        if let appleId = note.appleNoteId {
            do {
                let data = try await jxa.run(
                    operation: "notes_read",
                    scriptBody: Self.scriptReadNote,
                    input: .object(["appleNoteId": .string(appleId)])
                )
                let object = data.objectValue ?? [:]
                let bodyHTML = data.objectValue?["bodyHTML"]?.stringValue ?? note.bodyHTML ?? ""
                let bodyMarkdown = markdown.htmlToMarkdown(bodyHTML)
                current.title = object["title"]?.stringValue ?? current.title
                current.accountName = object["accountName"]?.stringValue ?? current.accountName
                current.folderPath = object["folderPath"]?.stringValue ?? current.folderPath
                current.updatedAt = object["updatedAt"]?.stringValue ?? current.updatedAt
                current.bodyHTML = bodyHTML
                current.bodyMarkdown = bodyMarkdown
                current.bodyHash = stableHash(bodyHTML)
                current.indexedAt = isoNow()
                try? await index(current, includeEmbeddings: false)
            } catch {
                warnings.append("Apple Notes read failed; returned cached SQLite content which may be stale.")
            }
        } else {
            warnings.append("No Apple note id available; returned cached SQLite content which may be stale.")
        }

        let includeHTML = args.bool("includeHTML", default: true)
        let includeMarkdown = args.bool("includeMarkdown", default: true)
        var object: [String: MCPValue] = [
            "noteId": .string(current.id),
            "appleNoteId": current.appleNoteId.map(MCPValue.string) ?? .null,
            "title": .string(current.title),
            "accountName": current.accountName.map(MCPValue.string) ?? .null,
            "folderPath": current.folderPath.map(MCPValue.string) ?? .null
        ]
        if includeHTML { object["bodyHTML"] = .string(current.bodyHTML ?? "") }
        if includeMarkdown { object["bodyMarkdown"] = .string(current.bodyMarkdown ?? "") }
        return (.object(object), warnings)
    }

    func index(_ note: IndexedNote, includeEmbeddings: Bool) async throws {
        try store.upsertNote(note)
        let text = note.bodyMarkdown ?? markdown.htmlToMarkdown(note.bodyHTML ?? "")
        let chunks = chunker.chunks(noteId: note.id, text: text)
        var vectors: [String: [Float]] = [:]
        if includeEmbeddings && config.embeddingsEnabled {
            for chunk in chunks {
                vectors[chunk.id] = try await embeddings.embed(chunk.text)
            }
        }
        try store.replaceChunks(noteId: note.id, chunks: chunks, embeddings: vectors)
    }

    func resolveNote(noteId: String?, title: String?) throws -> IndexedNote {
        if let noteId {
            guard let note = try store.noteById(noteId) else {
                throw NotesError.typed(code: "note_not_found", message: "Note not found: \(noteId)")
            }
            return note
        }
        guard let title else {
            throw NotesError.typed(code: "invalid_params", message: "Provide noteId or title.")
        }
        let matches = try store.notesByTitle(title)
        guard !matches.isEmpty else {
            throw NotesError.typed(code: "note_not_found", message: "Note not found: \(title)")
        }
        guard matches.count == 1 else {
            throw NotesError.typed(
                code: "ambiguous_note_title",
                message: "Multiple notes have this title. Use noteId.",
                details: ["title": title, "count": "\(matches.count)"]
            )
        }
        return matches[0]
    }

    private func indexedNote(
        data: MCPValue,
        fallbackTitle: String,
        fallbackAccount: String?,
        fallbackFolder: String?,
        bodyHTML: String,
        bodyMarkdown: String,
        tags: [String]
    ) -> IndexedNote {
        let object = data.objectValue ?? [:]
        let appleNoteId = object["appleNoteId"]?.stringValue
        let existing = appleNoteId.flatMap { try? store.noteByAppleId($0) }
        return IndexedNote(
            id: existing?.id ?? UUID().uuidString,
            appleNoteId: appleNoteId,
            accountName: object["accountName"]?.stringValue ?? fallbackAccount,
            folderPath: object["folderPath"]?.stringValue ?? fallbackFolder,
            title: object["title"]?.stringValue ?? fallbackTitle,
            bodyHTML: bodyHTML,
            bodyMarkdown: bodyMarkdown,
            bodyHash: stableHash(bodyHTML),
            createdAt: object["createdAt"]?.stringValue ?? existing?.createdAt ?? isoNow(),
            updatedAt: object["updatedAt"]?.stringValue ?? isoNow(),
            indexedAt: isoNow(),
            deletedAt: nil,
            tags: tags
        )
    }

    func folderSummariesValue(
        _ folders: [FolderSummary],
        liveCounts: [String: (childCount: Int, noteCount: Int)] = [:],
        warnings: [MCPValue] = []
    ) -> MCPValue {
        var object: [String: MCPValue] = [
            "folders": .array(folders.map { folder in
                let live = liveCounts["\(folder.accountName)\u{1F}\(folder.path)"]
                return .object([
                    "id": .string(folder.id),
                    "accountName": .string(folder.accountName),
                    "path": .string(folder.path),
                    "parentId": folder.parentId.map(MCPValue.string) ?? .null,
                    "childCount": .int(live?.childCount ?? folder.childCount),
                    "noteCount": .int(live?.noteCount ?? folder.noteCount)
                ])
            })
        ]
        if !warnings.isEmpty {
            object["warnings"] = .array(warnings)
        }
        return .object(object)
    }

    private func durationMS(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private func safeToolLogFields(
        arguments: [String: MCPValue],
        data: MCPValue? = nil,
        durationMS: Int,
        code: String? = nil
    ) -> [String: String] {
        var fields = ["duration_ms": "\(durationMS)"]
        if let code {
            fields["code"] = code
        }
        for key in ["noteId", "appleNoteId", "sourceNoteId", "targetNoteId"] {
            if let value = arguments[key]?.stringValue {
                fields[key] = value
            }
        }
        if let mode = arguments["mode"]?.stringValue {
            fields["mode"] = mode
        }
        if let object = data?.objectValue {
            for key in ["noteId", "appleNoteId", "sourceNoteId", "targetNoteId"] where fields[key] == nil {
                if let value = object[key]?.stringValue {
                    fields[key] = value
                }
            }
            if fields["mode"] == nil, let mode = object["mode"]?.stringValue {
                fields["mode"] = mode
            }
            for key in ["indexed", "skipped", "deletedMarked", "seen", "rebuildFTS", "rebuildVectors"] {
                if let value = object[key]?.intValue {
                    fields[key] = "\(value)"
                }
            }
            for (key, value) in object where key.lowercased().hasSuffix("count") || key == "count" {
                if let count = value.intValue {
                    fields[key] = "\(count)"
                }
            }
            for key in ["accounts", "folders", "results", "links", "backlinks"] {
                if let values = object[key]?.arrayValue {
                    fields["\(key)_count"] = "\(values.count)"
                }
            }
        }
        return fields
    }
}

extension NotesService {
    static let knownLimitations = [
        "Apple Notes automation may not expose every UI behavior.",
        "Markdown to rich text and HTML to Markdown are best effort.",
        "Apple Notes may simplify ordered lists, links, blockquotes, and code blocks when HTML is read back.",
        "Inaccessible Apple Notes folder references are skipped with warnings; the local folder cache is reconciled from reachable live folders without deleting notes.",
        "Native checklist state may not round-trip perfectly.",
        "Real attachments may fall back to file:// links.",
        "iCloud sync is controlled by Apple Notes and iCloud, not this MCP server.",
        "sqlite-vec is embedded; hybrid search falls back to FTS5 only if vector indexing fails."
    ]

    var knownLimitations: [String] { Self.knownLimitations }
}
