import Foundation

extension NotesService {
    func syncIndexData(_ args: [String: MCPValue]) async throws -> MCPValue {
        let mode = args.string("mode") ?? "incremental"
        guard mode == "incremental" || mode == "full" else {
            throw NotesError.typed(code: "invalid_params", message: "mode must be incremental or full.")
        }

        let lock = SyncLock(path: config.syncLockPath)
        if mode == "full" {
            guard try lock.acquire() else {
                throw NotesError.typed(
                    code: "sync_already_running",
                    message: "A full sync or rebuild is already running in another process."
                )
            }
        }
        defer { if mode == "full" { lock.release() } }

        let account = args.string("accountName")
        let folder = args.string("folderPath")
        let includeEmbeddings = args.bool("includeEmbeddings", default: true)
        let maxNotes = args["maxNotes"]?.intValue
        let data = try await jxa.run(
            operation: "notes_sync_index",
            scriptBody: Self.scriptListNotes,
            input: .object([
                "accountName": account.map(MCPValue.string) ?? .null,
                "folderPath": folder.map(MCPValue.string) ?? .null,
                "maxNotes": maxNotes.map(MCPValue.int) ?? .null
            ])
        )

        let notes = data.objectValue?["notes"]?.arrayValue ?? []
        var indexed = 0
        var skipped = 0
        var seenAppleIds = Set<String>()
        for item in notes {
            guard let object = item.objectValue else { continue }
            let bodyHTML = object["bodyHTML"]?.stringValue ?? ""
            let bodyMarkdown = markdown.htmlToMarkdown(bodyHTML)
            let appleId = object["appleNoteId"]?.stringValue
            if let appleId { seenAppleIds.insert(appleId) }
            let existing = appleId.flatMap { try? store.noteByAppleId($0) }
            let hash = stableHash(bodyHTML)
            if mode == "incremental", existing?.bodyHash == hash,
               existing?.title == object["title"]?.stringValue,
               existing?.folderPath == object["folderPath"]?.stringValue
            {
                skipped += 1
                continue
            }

            let note = IndexedNote(
                id: existing?.id ?? UUID().uuidString,
                appleNoteId: appleId,
                accountName: object["accountName"]?.stringValue,
                folderPath: object["folderPath"]?.stringValue,
                title: object["title"]?.stringValue ?? "Untitled",
                bodyHTML: bodyHTML,
                bodyMarkdown: bodyMarkdown,
                bodyHash: hash,
                createdAt: object["createdAt"]?.stringValue ?? existing?.createdAt,
                updatedAt: object["updatedAt"]?.stringValue ?? existing?.updatedAt,
                indexedAt: isoNow(),
                deletedAt: nil,
                tags: existing?.tags ?? []
            )
            try await index(note, includeEmbeddings: includeEmbeddings && config.embeddingsEnabled)
            indexed += 1
        }

        var deleted = 0
        if mode == "full" {
            deleted = try store.markMissingAsDeleted(
                seenAppleIds: seenAppleIds,
                accountName: account,
                folderPath: folder
            )
        }
        try store.setLastSync(isoNow())
        return .object([
            "mode": .string(mode),
            "indexed": .int(indexed),
            "skipped": .int(skipped),
            "deletedMarked": .int(deleted),
            "seen": .int(notes.count),
            "embeddingsIncluded": .bool(includeEmbeddings && config.embeddingsEnabled)
        ])
    }

    func rebuildSearchData(_ args: [String: MCPValue]) async throws -> (MCPValue, [String]) {
        let lock = SyncLock(path: config.syncLockPath)
        guard try lock.acquire() else {
            throw NotesError.typed(
                code: "sync_already_running",
                message: "A full sync or rebuild is already running in another process."
            )
        }
        defer { lock.release() }

        var warnings: [String] = []
        var ftsCount = 0
        var vectorCount = 0
        if args.bool("rebuildFTS", default: true) {
            ftsCount = try store.rebuildFTS()
        }
        if args.bool("rebuildVectors", default: true) {
            if !config.embeddingsEnabled {
                warnings.append("Embeddings disabled; vectors were not rebuilt.")
            } else {
                for note in try store.allNotes() {
                    let text = note.bodyMarkdown ?? markdown.htmlToMarkdown(note.bodyHTML ?? "")
                    let chunks = chunker.chunks(noteId: note.id, text: text)
                    var vectors: [String: [Float]] = [:]
                    for chunk in chunks {
                        vectors[chunk.id] = try await embeddings.embed(chunk.text)
                    }
                    try store.replaceChunks(noteId: note.id, chunks: chunks, embeddings: vectors)
                    vectorCount += chunks.count
                }
                if !store.vectorAvailable {
                    warnings.append("sqlite-vec unavailable; vectors cached in SQLite chunks for local fallback.")
                }
            }
        }
        return (.object(["rebuildFTS": .int(ftsCount), "rebuildVectors": .int(vectorCount)]), warnings)
    }

    func attachFileData(_ args: [String: MCPValue]) async throws -> (MCPValue, [String]) {
        var note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let rawPath = try args.requiredString("filePath")
        let url = try validatedAttachmentFileURL(rawPath: rawPath)
        let path = url.path
        let mode = args.string("mode") ?? "real_attachment_preferred"
        guard mode == "real_attachment_preferred" || mode == "file_link_only" else {
            throw NotesError.typed(code: "invalid_params", message: "mode must be real_attachment_preferred or file_link_only.")
        }

        let linkMarkdown = "[\(url.lastPathComponent)](\(url.absoluteString))"
        let linkHTML = markdown.markdownToHTML(linkMarkdown)
        if let appleId = note.appleNoteId {
            let newHTML = (note.bodyHTML ?? "") + "\n" + linkHTML
            _ = try await jxa.run(
                operation: "notes_attach_file",
                scriptBody: Self.scriptUpdateNote,
                input: .object(["appleNoteId": .string(appleId), "bodyHTML": .string(newHTML)])
            )
            note.bodyHTML = newHTML
            note.bodyMarkdown = (note.bodyMarkdown ?? "") + "\n\n" + linkMarkdown
            note.bodyHash = stableHash(newHTML)
            note.indexedAt = isoNow()
            try await index(note, includeEmbeddings: config.embeddingsEnabled)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let attachment = AttachmentRecord(
            id: UUID().uuidString,
            noteId: note.id,
            filePath: path,
            fileURL: url.absoluteString,
            filename: url.lastPathComponent,
            mimeType: nil,
            sizeBytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            attachedAs: "file_link_fallback",
            createdAt: isoNow()
        )
        try store.insertAttachment(attachment)
        return (
            .object([
                "noteId": .string(note.id),
                "filePath": .string(path),
                "attachedAs": .string("file_link_fallback"),
                "fileURL": .string(url.absoluteString)
            ]),
            mode == "real_attachment_preferred"
                ? ["Real Apple Notes attachments are not reliable through automation; inserted file:// link fallback."]
                : []
        )
    }

    func linkNotesData(_ args: [String: MCPValue]) async throws -> MCPValue {
        var source = try resolveNote(noteId: args.string("sourceNoteId"), title: args.string("sourceTitle"))
        let target = try resolveNote(noteId: args.string("targetNoteId"), title: args.string("targetTitle"))
        let mode = args.string("mode") ?? "wikilink"
        let linkText = args.string("linkText") ?? target.title
        let markdownLink: String
        if mode == "related_section" {
            markdownLink = "\n\n## Links relacionados\n- [[\(target.title)]]"
        } else {
            markdownLink = "[[\(linkText)]]"
        }

        let updatedMarkdown = (source.bodyMarkdown ?? markdown.htmlToMarkdown(source.bodyHTML ?? "")) + "\n\n" + markdownLink
        let updatedHTML = markdown.markdownToHTML(updatedMarkdown)
        if let appleId = source.appleNoteId {
            _ = try await jxa.run(
                operation: "notes_link",
                scriptBody: Self.scriptUpdateNote,
                input: .object(["appleNoteId": .string(appleId), "bodyHTML": .string(updatedHTML)])
            )
        }
        source.bodyMarkdown = updatedMarkdown
        source.bodyHTML = updatedHTML
        source.bodyHash = stableHash(updatedHTML)
        source.indexedAt = isoNow()
        try await index(source, includeEmbeddings: config.embeddingsEnabled)
        let link = LinkRecord(
            id: UUID().uuidString,
            sourceNoteId: source.id,
            targetNoteId: target.id,
            targetTitle: target.title,
            linkText: linkText,
            linkType: mode,
            createdAt: isoNow()
        )
        try store.insertLink(link)
        return .object([
            "sourceNoteId": .string(source.id),
            "targetNoteId": .string(target.id),
            "linkText": .string(linkText),
            "mode": .string(mode)
        ])
    }

    func backlinksData(_ args: [String: MCPValue]) throws -> MCPValue {
        let note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let records = try store.backlinks(targetNote: note)
        return .object([
            "noteId": .string(note.id),
            "title": .string(note.title),
            "backlinks": .array(records.map(linkValue))
        ])
    }

    func extractLinksData(_ args: [String: MCPValue]) throws -> MCPValue {
        let note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let text = note.bodyMarkdown ?? markdown.htmlToMarkdown(note.bodyHTML ?? "")
        let titles = extractWikiLinks(from: text)
        let links = titles.map { title in
            LinkRecord(
                id: UUID().uuidString,
                sourceNoteId: note.id,
                targetNoteId: (try? store.notesByTitle(title).first?.id) ?? nil,
                targetTitle: title,
                linkText: title,
                linkType: "wikilink_detected",
                createdAt: isoNow()
            )
        }
        try store.replaceDetectedLinks(sourceNoteId: note.id, links: links)
        return .object([
            "noteId": .string(note.id),
            "links": .array(links.map(linkValue))
        ])
    }

    private func linkValue(_ link: LinkRecord) -> MCPValue {
        .object([
            "id": .string(link.id),
            "sourceNoteId": .string(link.sourceNoteId),
            "targetNoteId": link.targetNoteId.map(MCPValue.string) ?? .null,
            "targetTitle": link.targetTitle.map(MCPValue.string) ?? .null,
            "linkText": link.linkText.map(MCPValue.string) ?? .null,
            "linkType": .string(link.linkType),
            "createdAt": .string(link.createdAt)
        ])
    }

    private func extractWikiLinks(from text: String) -> [String] {
        let pattern = #"\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

func validatedAttachmentFileURL(rawPath: String) throws -> URL {
    guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NotesError.typed(code: "invalid_params", message: "filePath must not be empty.")
    }

    let expanded = expandTilde(rawPath)
    guard expanded.hasPrefix("/") else {
        throw NotesError.typed(code: "invalid_params", message: "filePath must be absolute or start with ~/.")
    }

    let url = URL(fileURLWithPath: expanded)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else {
        throw NotesError.typed(code: "attachment_failed", message: "filePath does not exist or is a directory.")
    }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let type = attrs[.type] as? FileAttributeType,
          type == .typeRegular
    else {
        throw NotesError.typed(code: "attachment_failed", message: "filePath must be a regular file.")
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw NotesError.typed(code: "attachment_failed", message: "filePath is not readable.")
    }
    return url
}
