import Foundation

extension NotesService {
    func renameFolderData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let account = args.string("accountName") ?? config.defaultAccount
        let folderPath = try requiredFolderPath(args.requiredString("folderPath"))
        let newName = try folderNameComponent(args.requiredString("newName"))
        let data = try await jxa.run(
            operation: "notes_rename_folder",
            scriptBody: Self.scriptRenameFolder,
            input: .object([
                "accountName": .string(account),
                "folderPath": .string(folderPath),
                "newName": .string(newName)
            ])
        )
        let newPath = data.objectValue?["folderPath"]?.stringValue
            ?? replacingLastFolderComponent(path: folderPath, newName: newName)
        let changedNotes = try store.updateFolderPath(
            accountName: account,
            oldPath: folderPath,
            newPath: newPath
        )
        try store.upsertFolder(accountName: account, path: newPath)
        return .object([
            "accountName": .string(account),
            "oldPath": .string(folderPath),
            "folderPath": .string(newPath),
            "changedNoteCount": .int(changedNotes)
        ])
    }

    func moveFolderData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let account = args.string("accountName") ?? config.defaultAccount
        let folderPath = try requiredFolderPath(args.requiredString("folderPath"))
        let targetAccount = args.string("targetAccountName") ?? account
        let targetParent = normalizeFolderPath(try args.requiredString("targetParentFolderPath", allowEmpty: true))
        let newName = try args.string("newName").map(folderNameComponent)
        let createFolderIfMissing = args.bool("createFolderIfMissing", default: true)
        if account == targetAccount && isSameOrChildPath(targetParent, of: folderPath) {
            throw NotesError.typed(
                code: "invalid_params",
                message: "Cannot move a folder into itself or one of its children."
            )
        }

        let data = try await jxa.run(
            operation: "notes_move_folder",
            scriptBody: Self.scriptMoveFolder,
            input: .object([
                "accountName": .string(account),
                "folderPath": .string(folderPath),
                "targetAccountName": .string(targetAccount),
                "targetParentFolderPath": .string(targetParent),
                "newName": newName.map(MCPValue.string) ?? .null,
                "createFolderIfMissing": .bool(createFolderIfMissing)
            ])
        )
        let movedName = newName ?? lastFolderComponent(folderPath)
        let newPath = data.objectValue?["folderPath"]?.stringValue
            ?? joinFolderPath(targetParent, movedName)
        let changedNotes = try store.updateFolderPath(
            accountName: account,
            oldPath: folderPath,
            newPath: newPath,
            newAccountName: targetAccount
        )
        try store.upsertFolder(accountName: targetAccount, path: newPath)
        return .object([
            "oldAccountName": .string(account),
            "accountName": .string(targetAccount),
            "oldPath": .string(folderPath),
            "folderPath": .string(newPath),
            "changedNoteCount": .int(changedNotes)
        ])
    }

    func deleteFolderData(_ args: [String: MCPValue]) async throws -> MCPValue {
        guard args.bool("confirm", default: false) else {
            throw NotesError.typed(code: "invalid_params", message: "notes_delete_folder requires confirm=true.")
        }
        let account = args.string("accountName") ?? config.defaultAccount
        let folderPath = try requiredFolderPath(args.requiredString("folderPath"))
        _ = try await jxa.run(
            operation: "notes_delete_folder",
            scriptBody: Self.scriptDeleteFolder,
            input: .object([
                "accountName": .string(account),
                "folderPath": .string(folderPath)
            ])
        )
        let deletedNotes = try store.markFolderDeleted(accountName: account, path: folderPath)
        return .object([
            "accountName": .string(account),
            "folderPath": .string(folderPath),
            "deleted": .bool(true),
            "deletedNoteCount": .int(deletedNotes)
        ])
    }

    func searchNotesData(_ args: [String: MCPValue]) throws -> MCPValue {
        let notes = try selectedNotes(args, requireSelector: false)
        return notesListValue(notes)
    }

    func renameNoteData(_ args: [String: MCPValue]) async throws -> MCPValue {
        var note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let newTitle = try args.requiredString("newTitle").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            throw NotesError.typed(code: "invalid_params", message: "newTitle must not be empty.")
        }
        guard let appleId = note.appleNoteId else {
            throw NotesError.typed(code: "note_not_found", message: "Cannot rename Apple Notes note without appleNoteId.")
        }

        let readData = try await jxa.run(
            operation: "notes_read",
            scriptBody: Self.scriptReadNote,
            input: .object(["appleNoteId": .string(appleId)])
        )
        let currentHTML = readData.objectValue?["bodyHTML"]?.stringValue ?? note.bodyHTML ?? ""
        let finalHTML = composeAppleNotesRenameHTML(
            oldTitle: note.title,
            newTitle: newTitle,
            currentHTML: currentHTML
        )
        let data = try await jxa.run(
            operation: "notes_rename_note",
            scriptBody: Self.scriptRenameNote,
            input: .object([
                "appleNoteId": .string(appleId),
                "newTitle": .string(newTitle),
                "bodyHTML": .string(finalHTML)
            ])
        )
        let object = data.objectValue ?? [:]
        note.title = object["title"]?.stringValue ?? newTitle
        note.accountName = object["accountName"]?.stringValue ?? note.accountName
        note.folderPath = object["folderPath"]?.stringValue ?? note.folderPath
        note.bodyHTML = object["bodyHTML"]?.stringValue ?? finalHTML
        note.bodyMarkdown = markdown.htmlToMarkdown(note.bodyHTML ?? "")
        note.bodyHash = stableHash(note.bodyHTML ?? "")
        note.updatedAt = object["updatedAt"]?.stringValue ?? isoNow()
        note.indexedAt = isoNow()
        try await index(note, includeEmbeddings: config.embeddingsEnabled)
        return .object([
            "noteId": .string(note.id),
            "appleNoteId": .string(appleId),
            "title": .string(note.title),
            "renamed": .bool(true)
        ])
    }

    func bulkMoveNotesData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let targetFolder = try requiredFolderPath(args.requiredString("targetFolderPath"))
        let targetAccount = args.string("targetAccountName") ?? args.string("accountName") ?? config.defaultAccount
        let createFolderIfMissing = args.bool("createFolderIfMissing", default: true)
        let notes = try selectedNotes(args, requireSelector: true)
        var moved = 0
        var skipped = 0
        var failures: [MCPValue] = []

        for note in notes {
            guard let appleId = note.appleNoteId else {
                skipped += 1
                continue
            }
            do {
                let data = try await jxa.run(
                    operation: "notes_bulk_move_notes",
                    scriptBody: Self.scriptMoveNote,
                    input: .object([
                        "appleNoteId": .string(appleId),
                        "targetAccountName": .string(targetAccount),
                        "targetFolderPath": .string(targetFolder),
                        "createFolderIfMissing": .bool(createFolderIfMissing)
                    ])
                )
                let account = data.objectValue?["accountName"]?.stringValue ?? targetAccount
                let folder = data.objectValue?["folderPath"]?.stringValue ?? targetFolder
                try store.updateNoteLocation(noteId: note.id, accountName: account, folderPath: folder)
                moved += 1
            } catch let error as NotesError {
                failures.append(.object([
                    "noteId": .string(note.id),
                    "code": .string(error.code)
                ]))
            } catch {
                failures.append(.object([
                    "noteId": .string(note.id),
                    "code": .string("internal_error")
                ]))
            }
        }

        return .object([
            "matchedCount": .int(notes.count),
            "movedCount": .int(moved),
            "skippedCount": .int(skipped),
            "failedCount": .int(failures.count),
            "targetAccountName": .string(targetAccount),
            "targetFolderPath": .string(targetFolder),
            "failures": .array(failures)
        ])
    }

    func bulkArchiveNotesData(_ args: [String: MCPValue]) async throws -> MCPValue {
        var archiveArgs = args
        archiveArgs["targetFolderPath"] = .string(args.string("archiveFolderPath") ?? "Archive")
        let result = try await bulkMoveNotesData(archiveArgs)
        var object = result.objectValue ?? [:]
        object["archived"] = .bool(true)
        return .object(object)
    }

    func bulkDeleteNotesData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let dryRun = args.bool("dryRun", default: true)
        if !dryRun && !args.bool("confirm", default: false) {
            throw NotesError.typed(code: "invalid_params", message: "bulk delete requires confirm=true when dryRun=false.")
        }
        let notes = try selectedNotes(args, requireSelector: true)
        if dryRun {
            return .object([
                "dryRun": .bool(true),
                "matchedCount": .int(notes.count),
                "notes": notesMetadataValue(notes)
            ])
        }

        var deleted = 0
        var failures: [MCPValue] = []
        for note in notes {
            do {
                if let appleId = note.appleNoteId {
                    _ = try await jxa.run(
                        operation: "notes_bulk_delete_notes",
                        scriptBody: Self.scriptDeleteNote,
                        input: .object(["appleNoteId": .string(appleId)])
                    )
                }
                try store.markDeleted(noteId: note.id)
                deleted += 1
            } catch let error as NotesError {
                failures.append(.object([
                    "noteId": .string(note.id),
                    "code": .string(error.code)
                ]))
            } catch {
                failures.append(.object([
                    "noteId": .string(note.id),
                    "code": .string("internal_error")
                ]))
            }
        }
        return .object([
            "dryRun": .bool(false),
            "matchedCount": .int(notes.count),
            "deletedCount": .int(deleted),
            "failedCount": .int(failures.count),
            "failures": .array(failures)
        ])
    }

    func mergeFoldersData(_ args: [String: MCPValue]) async throws -> MCPValue {
        guard args.bool("confirm", default: false) else {
            throw NotesError.typed(code: "invalid_params", message: "notes_merge_folders requires confirm=true.")
        }
        let account = args.string("accountName") ?? config.defaultAccount
        let sourceFolder = try requiredFolderPath(args.requiredString("sourceFolderPath"))
        let targetFolder = try requiredFolderPath(args.requiredString("targetFolderPath"))

        _ = try await listFoldersData(accountName: account)
        let summaries = try store.listFolderSummaries(accountName: account)
        if let source = summaries.first(where: { $0.accountName == account && $0.path == sourceFolder }),
           source.childCount > 0
        {
            throw NotesError.typed(
                code: "folder_not_empty",
                message: "Source folder has child folders. Move or delete child folders before merging."
            )
        }

        var moveArgs = args
        moveArgs["folderPath"] = .string(sourceFolder)
        moveArgs["targetFolderPath"] = .string(targetFolder)
        moveArgs["accountName"] = .string(account)
        let moveResult = try await bulkMoveNotesData(moveArgs)
        _ = try await jxa.run(
            operation: "notes_merge_folders",
            scriptBody: Self.scriptDeleteFolder,
            input: .object([
                "accountName": .string(account),
                "folderPath": .string(sourceFolder)
            ])
        )
        _ = try store.markFolderDeleted(accountName: account, path: sourceFolder)
        var object = moveResult.objectValue ?? [:]
        object["sourceFolderPath"] = .string(sourceFolder)
        object["targetFolderPath"] = .string(targetFolder)
        object["sourceDeleted"] = .bool(true)
        return .object(object)
    }

    func updateNoteData(_ args: [String: MCPValue]) async throws -> MCPValue {
        var note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let bodyMarkdown = try args.requiredString("bodyMarkdown")
        let mode = args.string("mode") ?? "replace"
        let confirm = args.bool("confirm", default: false)
        guard ["replace", "append", "prepend"].contains(mode) else {
            throw NotesError.typed(code: "invalid_params", message: "mode must be replace, append, or prepend.")
        }
        if mode == "replace" && !confirm {
            throw NotesError.typed(code: "invalid_params", message: "replace requires confirm=true.")
        }

        let incomingHTML = markdown.markdownToHTML(bodyMarkdown)
        let currentHTML = note.bodyHTML ?? ""
        let finalHTML = composeAppleNotesUpdateHTML(
            title: note.title,
            currentHTML: currentHTML,
            incomingHTML: incomingHTML,
            mode: mode
        )

        if let appleId = note.appleNoteId {
            let data = try await jxa.run(
                operation: "notes_update",
                scriptBody: Self.scriptUpdateNote,
                input: .object([
                    "appleNoteId": .string(appleId),
                    "bodyHTML": .string(finalHTML)
                ])
            )
            let object = data.objectValue ?? [:]
            note.title = object["title"]?.stringValue ?? note.title
            note.accountName = object["accountName"]?.stringValue ?? note.accountName
            note.folderPath = object["folderPath"]?.stringValue ?? note.folderPath
            note.bodyHTML = object["bodyHTML"]?.stringValue ?? finalHTML
            note.bodyMarkdown = markdown.htmlToMarkdown(note.bodyHTML ?? "")
            note.updatedAt = object["updatedAt"]?.stringValue ?? isoNow()
        } else {
            throw NotesError.typed(
                code: "note_not_found",
                message: "Cannot update Apple Notes note without appleNoteId."
            )
        }

        note.bodyHash = stableHash(note.bodyHTML ?? "")
        note.indexedAt = isoNow()
        try await index(note, includeEmbeddings: config.embeddingsEnabled)
        return .object([
            "noteId": .string(note.id),
            "appleNoteId": note.appleNoteId.map(MCPValue.string) ?? .null,
            "title": .string(note.title),
            "mode": .string(mode),
            "indexed": .bool(true)
        ])
    }

    func deleteNoteData(_ args: [String: MCPValue]) async throws -> MCPValue {
        guard args.bool("confirm", default: false) else {
            throw NotesError.typed(code: "invalid_params", message: "notes_delete requires confirm=true.")
        }
        let note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        if let appleId = note.appleNoteId {
            _ = try await jxa.run(
                operation: "notes_delete",
                scriptBody: Self.scriptDeleteNote,
                input: .object(["appleNoteId": .string(appleId)])
            )
        }
        try store.markDeleted(noteId: note.id)
        return .object([
            "noteId": .string(note.id),
            "appleNoteId": note.appleNoteId.map(MCPValue.string) ?? .null,
            "deleted": .bool(true)
        ])
    }

    func moveNoteData(_ args: [String: MCPValue]) async throws -> MCPValue {
        var note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let targetFolder = try requiredFolderPath(args.requiredString("targetFolderPath"))
        let targetAccount = args.string("targetAccountName") ?? note.accountName ?? config.defaultAccount
        let createFolderIfMissing = args.bool("createFolderIfMissing", default: true)
        guard let appleId = note.appleNoteId else {
            throw NotesError.typed(code: "note_not_found", message: "Cannot move note without appleNoteId.")
        }
        let data = try await jxa.run(
            operation: "notes_move",
            scriptBody: Self.scriptMoveNote,
            input: .object([
                "appleNoteId": .string(appleId),
                "targetAccountName": .string(targetAccount),
                "targetFolderPath": .string(targetFolder),
                "createFolderIfMissing": .bool(createFolderIfMissing)
            ])
        )
        note.accountName = data.objectValue?["accountName"]?.stringValue ?? targetAccount
        note.folderPath = data.objectValue?["folderPath"]?.stringValue ?? targetFolder
        note.indexedAt = isoNow()
        try await index(note, includeEmbeddings: false)
        return .object([
            "noteId": .string(note.id),
            "appleNoteId": .string(appleId),
            "accountName": note.accountName.map(MCPValue.string) ?? .null,
            "folderPath": note.folderPath.map(MCPValue.string) ?? .null,
            "moved": .bool(true)
        ])
    }

    func searchFTSData(_ args: [String: MCPValue]) throws -> MCPValue {
        let query = try args.requiredString("query")
        let results = try store.searchFTS(
            query: query,
            limit: boundedSearchLimit(args.int("limit", default: 10)),
            accountName: args.string("accountName"),
            folderPath: args.string("folderPath")
        )
        return searchResultsValue(results)
    }

    func searchRAGData(_ args: [String: MCPValue]) async throws -> (MCPValue, [String]) {
        guard config.embeddingsEnabled else {
            throw NotesError.typed(
                code: "embedding_provider_unavailable",
                message: "Embeddings are disabled.",
                details: ["suggestion": "Use notes_search_fts or notes_search_hybrid."]
            )
        }
        let query = try args.requiredString("query")
        let vector = try await embeddings.embed(query)
        let results = try store.searchVector(
            queryVector: vector,
            limit: boundedSearchLimit(args.int("limit", default: 10)),
            accountName: args.string("accountName"),
            folderPath: args.string("folderPath")
        )
        return (searchResultsValue(results), config.embeddingWarnings)
    }

    func searchHybridData(_ args: [String: MCPValue]) async throws -> (MCPValue, [String]) {
        let query = try args.requiredString("query")
        let limit = boundedSearchLimit(args.int("limit", default: 10))
        let candidateLimit = hybridCandidateLimit(for: limit)
        let lexicalWeight = args.double("lexicalWeight", default: 0.65)
        let vectorWeight = args.double("vectorWeight", default: 0.35)
        let accountName = args.string("accountName")
        let folderPath = args.string("folderPath")
        let fts = try store.searchFTS(
            query: query,
            limit: candidateLimit,
            accountName: accountName,
            folderPath: folderPath
        )

        var warnings = config.embeddingWarnings
        let lexicalScores = normalizedScores(
            Dictionary(uniqueKeysWithValues: fts.map { ($0.noteId, -$0.score) })
        )
        var combined: [String: SearchResult] = [:]

        for result in fts {
            let lexicalScore = lexicalScores[result.noteId] ?? 0
            let combinedScore = lexicalWeight * lexicalScore
            combined[result.noteId] = SearchResult(
                score: combinedScore,
                title: result.title,
                snippet: result.snippet,
                noteId: result.noteId,
                accountName: result.accountName,
                folderPath: result.folderPath,
                lexicalScore: lexicalScore,
                vectorScore: 0,
                combinedScore: combinedScore,
                rankReason: hybridRankReason(
                    lexicalScore: lexicalScore,
                    vectorScore: 0,
                    fallbackReason: nil
                )
            )
        }

        if config.embeddingsEnabled {
            do {
                let vector = try await embeddings.embed(query)
                let vectorCandidates = try store.searchVector(
                    queryVector: vector,
                    limit: candidateLimit,
                    accountName: accountName,
                    folderPath: folderPath
                )
                let bestVectorByNote = bestVectorCandidatesByNote(vectorCandidates)
                let vectorScores = normalizedScores(
                    Dictionary(uniqueKeysWithValues: bestVectorByNote.map { ($0.noteId, $0.score) })
                )
                for result in bestVectorByNote {
                    let lexicalScore = combined[result.noteId]?.lexicalScore ?? 0
                    let vectorScore = vectorScores[result.noteId] ?? 0
                    let combinedScore = (lexicalWeight * lexicalScore) + (vectorWeight * vectorScore)
                    let existing = combined[result.noteId]
                    combined[result.noteId] = SearchResult(
                        score: combinedScore,
                        title: existing?.title ?? result.title,
                        snippet: existing?.snippet.isEmpty == false ? existing?.snippet ?? "" : result.snippet,
                        noteId: result.noteId,
                        accountName: existing?.accountName ?? result.accountName,
                        folderPath: existing?.folderPath ?? result.folderPath,
                        lexicalScore: lexicalScore,
                        vectorScore: vectorScore,
                        combinedScore: combinedScore,
                        rankReason: hybridRankReason(
                            lexicalScore: lexicalScore,
                            vectorScore: vectorScore,
                            fallbackReason: nil
                        ),
                        chunkIndex: result.chunkIndex
                    )
                }
            } catch let error as NotesError {
                warnings.append("Vector search unavailable (\(error.code)); returned FTS5 results only.")
                combined = combined.mapValues { result in
                    let lexicalScore = result.lexicalScore ?? 0
                    let combinedScore = lexicalWeight * lexicalScore
                    return SearchResult(
                        score: combinedScore,
                        title: result.title,
                        snippet: result.snippet,
                        noteId: result.noteId,
                        accountName: result.accountName,
                        folderPath: result.folderPath,
                        lexicalScore: lexicalScore,
                        vectorScore: 0,
                        combinedScore: combinedScore,
                        rankReason: hybridRankReason(
                            lexicalScore: lexicalScore,
                            vectorScore: 0,
                            fallbackReason: "fts_fallback_vector_unavailable"
                        )
                    )
                }
            } catch {
                warnings.append("Vector search unavailable; returned FTS5 results only.")
                combined = combined.mapValues { result in
                    let lexicalScore = result.lexicalScore ?? 0
                    let combinedScore = lexicalWeight * lexicalScore
                    return SearchResult(
                        score: combinedScore,
                        title: result.title,
                        snippet: result.snippet,
                        noteId: result.noteId,
                        accountName: result.accountName,
                        folderPath: result.folderPath,
                        lexicalScore: lexicalScore,
                        vectorScore: 0,
                        combinedScore: combinedScore,
                        rankReason: hybridRankReason(
                            lexicalScore: lexicalScore,
                            vectorScore: 0,
                            fallbackReason: "fts_fallback_vector_unavailable"
                        )
                    )
                }
            }
        } else {
            warnings.append("Embeddings disabled; returned FTS5 results only.")
            combined = combined.mapValues { result in
                let lexicalScore = result.lexicalScore ?? 0
                let combinedScore = lexicalWeight * lexicalScore
                return SearchResult(
                    score: combinedScore,
                    title: result.title,
                    snippet: result.snippet,
                    noteId: result.noteId,
                    accountName: result.accountName,
                    folderPath: result.folderPath,
                    lexicalScore: lexicalScore,
                    vectorScore: 0,
                    combinedScore: combinedScore,
                    rankReason: hybridRankReason(
                        lexicalScore: lexicalScore,
                        vectorScore: 0,
                        fallbackReason: "fts_fallback_embeddings_disabled"
                    )
                )
            }
        }

        let results = combined.values
            .sorted(by: prefersHybridResult)
            .prefix(limit)
        return (searchResultsValue(Array(results)), warnings)
    }

    private func searchResultsValue(_ results: [SearchResult]) -> MCPValue {
        .object([
            "results": .array(results.map { result in
                var object: [String: MCPValue] = [
                    "score": .double(result.score),
                    "title": .string(result.title),
                    "snippet": .string(result.snippet),
                    "noteId": .string(result.noteId),
                    "accountName": result.accountName.map(MCPValue.string) ?? .null,
                    "folderPath": result.folderPath.map(MCPValue.string) ?? .null
                ]
                if let lexicalScore = result.lexicalScore {
                    object["lexicalScore"] = .double(lexicalScore)
                }
                if let vectorScore = result.vectorScore {
                    object["vectorScore"] = .double(vectorScore)
                }
                if let combinedScore = result.combinedScore {
                    object["combinedScore"] = .double(combinedScore)
                }
                if let rankReason = result.rankReason {
                    object["rankReason"] = .string(rankReason)
                }
                if let chunkIndex = result.chunkIndex {
                    object["chunkIndex"] = .int(chunkIndex)
                }
                return .object(object)
            })
        ])
    }

    private func selectedNotes(_ args: [String: MCPValue], requireSelector: Bool) throws -> [IndexedNote] {
        let limit = boundedBulkLimit(args.int("limit", default: 100))
        let noteIds = args["noteIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let accountName = args.string("accountName")
        let folderPath = args.string("folderPath").map(normalizeFolderPath).flatMap { $0.isEmpty ? nil : $0 }
        let title = args.string("title")
        let titleQuery = args.string("titleQuery")
        if requireSelector && noteIds.isEmpty && folderPath == nil && title == nil && titleQuery == nil {
            throw NotesError.typed(
                code: "invalid_params",
                message: "Provide noteIds, folderPath, title, or titleQuery for bulk operations."
            )
        }

        let notes: [IndexedNote]
        if !noteIds.isEmpty {
            notes = try noteIds.compactMap { try store.noteById($0) }
        } else {
            notes = try store.searchNotes(
                title: title,
                titleQuery: titleQuery,
                accountName: accountName,
                folderPath: folderPath,
                limit: limit
            )
        }

        return Array(notes.filter { note in
            matchesNoteFilters(
                note,
                accountName: accountName,
                folderPath: folderPath,
                title: title,
                titleQuery: titleQuery
            )
        }.prefix(limit))
    }

    private func matchesNoteFilters(
        _ note: IndexedNote,
        accountName: String?,
        folderPath: String?,
        title: String?,
        titleQuery: String?
    ) -> Bool {
        if let accountName, note.accountName != accountName { return false }
        if let folderPath, note.folderPath != folderPath { return false }
        if let title, note.title != title { return false }
        if let titleQuery, !note.title.localizedCaseInsensitiveContains(titleQuery) { return false }
        return true
    }

    private func notesListValue(_ notes: [IndexedNote]) -> MCPValue {
        .object([
            "notes": notesMetadataValue(notes),
            "count": .int(notes.count)
        ])
    }

    private func notesMetadataValue(_ notes: [IndexedNote]) -> MCPValue {
        .array(notes.map { note in
            .object([
                "noteId": .string(note.id),
                "appleNoteId": note.appleNoteId.map(MCPValue.string) ?? .null,
                "title": .string(note.title),
                "accountName": note.accountName.map(MCPValue.string) ?? .null,
                "folderPath": note.folderPath.map(MCPValue.string) ?? .null,
                "updatedAt": note.updatedAt.map(MCPValue.string) ?? .null,
                "hasAppleNoteId": .bool(note.appleNoteId != nil)
            ])
        })
    }
}

func composeAppleNotesUpdateHTML(
    title: String,
    currentHTML: String,
    incomingHTML: String,
    mode: String
) -> String {
    let bodyWithTitle = htmlByEnsuringLeadingTitle(title: title, html: currentHTML)
    switch mode {
    case "append":
        return joinHTML(bodyWithTitle, incomingHTML)
    case "prepend":
        return htmlByInsertingAfterLeadingTitle(title: title, html: bodyWithTitle, insertion: incomingHTML)
    default:
        return joinHTML(appleNotesTitleBlock(title), incomingHTML)
    }
}

func composeAppleNotesRenameHTML(
    oldTitle: String,
    newTitle: String,
    currentHTML: String
) -> String {
    let trimmed = currentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    let oldTitleBlock = appleNotesTitleBlock(oldTitle)
    let newTitleBlock = appleNotesTitleBlock(newTitle)
    if trimmed.hasPrefix(newTitleBlock) {
        return trimmed
    }
    if trimmed.hasPrefix(oldTitleBlock) {
        let remainder = String(trimmed.dropFirst(oldTitleBlock.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joinHTML(newTitleBlock, remainder)
    }
    return joinHTML(newTitleBlock, trimmed)
}

private func htmlByEnsuringLeadingTitle(title: String, html: String) -> String {
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return appleNotesTitleBlock(title) }
    guard !trimmed.hasPrefix(appleNotesTitleBlock(title)) else { return trimmed }
    return joinHTML(appleNotesTitleBlock(title), trimmed)
}

private func htmlByInsertingAfterLeadingTitle(title: String, html: String, insertion: String) -> String {
    let titleBlock = appleNotesTitleBlock(title)
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(titleBlock) else {
        return joinHTML(titleBlock, insertion, trimmed)
    }
    let remainder = String(trimmed.dropFirst(titleBlock.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    return joinHTML(titleBlock, insertion, remainder)
}

private func appleNotesTitleBlock(_ title: String) -> String {
    "<div>\(escapeAppleNotesHTML(title))</div>"
}

private func joinHTML(_ parts: String...) -> String {
    parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func escapeAppleNotesHTML(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func boundedSearchLimit(_ limit: Int) -> Int {
    max(1, min(limit, 50))
}

private func hybridCandidateLimit(for limit: Int) -> Int {
    max(limit * 5, 30)
}

private func boundedBulkLimit(_ limit: Int) -> Int {
    max(1, min(limit, 500))
}

func normalizeFolderPath(_ value: String) -> String {
    value
        .split(separator: "/")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "/")
}

func requiredFolderPath(_ value: String) throws -> String {
    let path = normalizeFolderPath(value)
    guard !path.isEmpty else {
        throw NotesError.typed(code: "invalid_params", message: "Folder path must not be empty.")
    }
    return path
}

private func folderNameComponent(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/") else {
        throw NotesError.typed(code: "invalid_params", message: "Folder name must not be empty or contain '/'.")
    }
    return trimmed
}

private func replacingLastFolderComponent(path: String, newName: String) -> String {
    var parts = path.split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return newName }
    parts[parts.count - 1] = newName
    return parts.joined(separator: "/")
}

private func lastFolderComponent(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private func joinFolderPath(_ parent: String, _ child: String) -> String {
    parent.isEmpty ? child : "\(parent)/\(child)"
}

private func isSameOrChildPath(_ path: String, of parent: String) -> Bool {
    path == parent || path.hasPrefix(parent + "/")
}

private func normalizedScores(_ rawScores: [String: Double]) -> [String: Double] {
    let finiteScores = rawScores.filter { $0.value.isFinite }
    guard let minScore = finiteScores.values.min(),
          let maxScore = finiteScores.values.max()
    else { return [:] }

    guard maxScore > minScore else {
        return rawScores.mapValues { $0.isFinite ? 1 : 0 }
    }

    return rawScores.mapValues { value in
        guard value.isFinite else { return 0 }
        return max(0, min(1, (value - minScore) / (maxScore - minScore)))
    }
}

private func bestVectorCandidatesByNote(_ candidates: [SearchResult]) -> [SearchResult] {
    var bestByNote: [String: SearchResult] = [:]
    for candidate in candidates {
        if let existing = bestByNote[candidate.noteId], existing.score >= candidate.score {
            continue
        }
        bestByNote[candidate.noteId] = candidate
    }
    return bestByNote.values.sorted { $0.score > $1.score }
}

private func hybridRankReason(
    lexicalScore: Double,
    vectorScore: Double,
    fallbackReason: String?
) -> String {
    if let fallbackReason {
        return fallbackReason
    }
    if lexicalScore >= 0.75, vectorScore > 0 {
        return "lexical_and_vector_match"
    }
    if lexicalScore >= 0.75 {
        return "strong_lexical_match"
    }
    if vectorScore > 0 {
        return "semantic_chunk_match"
    }
    return "weak_match"
}

private func prefersHybridResult(_ left: SearchResult, _ right: SearchResult) -> Bool {
    let leftCombined = left.combinedScore ?? left.score
    let rightCombined = right.combinedScore ?? right.score
    if abs(leftCombined - rightCombined) <= 0.03 {
        let leftLexical = left.lexicalScore ?? 0
        let rightLexical = right.lexicalScore ?? 0
        if abs(leftLexical - rightLexical) > 0.000_001 {
            return leftLexical > rightLexical
        }
    }
    if abs(leftCombined - rightCombined) > 0.000_001 {
        return leftCombined > rightCombined
    }
    let leftVector = left.vectorScore ?? 0
    let rightVector = right.vectorScore ?? 0
    if abs(leftVector - rightVector) > 0.000_001 {
        return leftVector > rightVector
    }
    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
}
