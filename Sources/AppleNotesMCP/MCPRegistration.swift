import Foundation
import MCP

func registerMCPHandlers(server: Server, service: NotesService) async {
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: toolDefinitions())
    }

    await server.withMethodHandler(CallTool.self) { params in
        let (value, isError) = await service.callTool(
            name: params.name,
            arguments: params.arguments ?? [:]
        )
        return CallTool.Result(
            content: [.text(text: valueToJSONString(value), annotations: nil, _meta: nil)],
            structuredContent: Optional<MCPValue>.some(value),
            isError: isError
        )
    }

    await server.withMethodHandler(ListResources.self) { _ in
        ListResources.Result(resources: resources())
    }

    await server.withMethodHandler(ReadResource.self) { params in
        let content: String
        switch params.uri {
        case "notes://health":
            content = valueToJSONString(await service.health())
        case "notes://schema":
            content = schemaText
        case "notes://limitations":
            content = NotesService.knownLimitations.map { "- \($0)" }.joined(separator: "\n")
        case "notes://config":
            content = valueToJSONString(service.store.configSummary(
                defaultAccount: service.config.defaultAccount,
                embeddingsEnabled: service.config.embeddingsEnabled,
                embeddingProvider: service.config.embeddingProvider,
                embeddingDimension: service.config.embeddingDimension,
                embeddingLanguage: service.config.embeddingLanguage,
                embeddingWarnings: service.config.embeddingWarnings
            ))
        case "notes://stats":
            let count = (try? service.store.noteCount()) ?? 0
            let lastSync = (try? service.store.lastSync()) ?? nil
            content = valueToJSONString(.object([
                "indexedNoteCount": .int(count),
                "lastSync": lastSync.map(MCPValue.string) ?? .null,
                "vectorSearchAvailable": .bool(service.store.vectorAvailable)
            ]))
        default:
            throw MCPError.invalidRequest("Unknown resource URI: \(params.uri)")
        }
        return ReadResource.Result(contents: [.text(content, uri: params.uri, mimeType: "text/plain")])
    }

    await server.withMethodHandler(ListPrompts.self) { _ in
        ListPrompts.Result(prompts: promptDefinitions())
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        guard let text = promptTemplate(name: params.name, arguments: params.arguments ?? [:]) else {
            throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
        }
        return GetPrompt.Result(
            description: "Apple Notes note template",
            messages: [.user(.text(text: text))]
        )
    }
}

private func toolDefinitions() -> [Tool] {
    [
        tool("notes_health", "Return server status, config, permissions, counts, and limitations.", [:], readOnly: true),
        tool("notes_list_accounts", "List Apple Notes accounts.", [:], readOnly: true),
        tool("notes_list_folders", "List Apple Notes folders.", ["accountName": stringSchema(required: false)], readOnly: true),
        tool("notes_create_folder", "Create an Apple Notes folder idempotently.", ["accountName": stringSchema(required: false), "folderPath": stringSchema()], required: ["folderPath"]),
        tool("notes_rename_folder", "Rename an Apple Notes folder.", [
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(),
            "newName": stringSchema()
        ], required: ["folderPath", "newName"]),
        tool("notes_move_folder", "Move an Apple Notes folder under another parent folder.", [
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(),
            "targetAccountName": stringSchema(required: false),
            "targetParentFolderPath": stringSchema(),
            "newName": stringSchema(required: false),
            "createFolderIfMissing": boolSchema(defaultValue: true)
        ], required: ["folderPath", "targetParentFolderPath"]),
        tool("notes_delete_folder", "Delete an Apple Notes folder after explicit confirmation.", [
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(),
            "confirm": boolSchema(defaultValue: false)
        ], required: ["folderPath"], destructive: true),
        tool("notes_create", "Create a note in Apple Notes from Markdown.", [
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(required: false),
            "title": stringSchema(),
            "bodyMarkdown": stringSchema(),
            "tags": arraySchema(),
            "experimentalNativeUI": boolSchema(defaultValue: false),
            "preserveFormatting": boolSchema(defaultValue: true)
        ], required: ["title", "bodyMarkdown"]),
        tool("notes_read", "Read a note by noteId or title.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "includeHTML": boolSchema(defaultValue: true),
            "includeMarkdown": boolSchema(defaultValue: true)
        ], readOnly: true),
        tool("notes_update", "Update a note by replacing, appending, or prepending Markdown.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "bodyMarkdown": stringSchema(),
            "mode": enumSchema(["replace", "append", "prepend"]),
            "preserveFormatting": boolSchema(defaultValue: true),
            "confirm": boolSchema(defaultValue: false)
        ], required: ["bodyMarkdown", "mode"]),
        tool("notes_rename_note", "Rename a note and preserve the Apple Notes title line.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "newTitle": stringSchema()
        ], required: ["newTitle"]),
        tool("notes_delete", "Delete a note from Apple Notes and mark it deleted in SQLite.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "confirm": boolSchema(defaultValue: false)
        ], destructive: true),
        tool("notes_move", "Move a note to another Apple Notes folder.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "targetAccountName": stringSchema(required: false),
            "targetFolderPath": stringSchema(),
            "createFolderIfMissing": boolSchema(defaultValue: true)
        ], required: ["targetFolderPath"]),
        tool("notes_search_notes", "Search indexed note metadata by folder and title filters.", noteSelectionSchema(), readOnly: true),
        tool("notes_search_fts", "Search indexed notes with SQLite FTS5.", searchSchema(), required: ["query"], readOnly: true),
        tool("notes_search_rag", "Search indexed chunks with local embeddings through sqlite-vec.", searchSchema(), required: ["query"], readOnly: true),
        tool("notes_search_hybrid", "Combine FTS5 and sqlite-vec results with score components and fallback warnings.", [
            "query": stringSchema(),
            "limit": intSchema(defaultValue: 10),
            "lexicalWeight": numberSchema(defaultValue: 0.65),
            "vectorWeight": numberSchema(defaultValue: 0.35),
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(required: false)
        ], required: ["query"], readOnly: true),
        tool("notes_sync_index", "Run manual incremental or full sync into SQLite.", [
            "mode": enumSchema(["incremental", "full"]),
            "accountName": stringSchema(required: false),
            "folderPath": stringSchema(required: false),
            "includeEmbeddings": boolSchema(defaultValue: true),
            "maxNotes": intSchema(required: false)
        ], required: ["mode"]),
        tool("notes_rebuild_search", "Rebuild FTS and local vector cache from SQLite notes.", [
            "rebuildFTS": boolSchema(defaultValue: true),
            "rebuildVectors": boolSchema(defaultValue: true)
        ]),
        tool("notes_attach_file", "Attach a file by real attachment when reliable, otherwise file:// fallback.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "filePath": stringSchema(),
            "mode": enumSchema(["real_attachment_preferred", "file_link_only"]),
            "copyToManagedFolder": boolSchema(defaultValue: false)
        ], required: ["filePath", "mode"]),
        tool("notes_bulk_move_notes", "Move a selected batch of notes to a target folder.", bulkMoveSchema(), required: ["targetFolderPath"]),
        tool("notes_bulk_archive_notes", "Move a selected batch of notes to an archive folder.", bulkArchiveSchema()),
        tool("notes_bulk_delete_notes", "Delete a selected batch of notes, defaulting to dry run.", bulkDeleteSchema(), destructive: true),
        tool("notes_merge_folders", "Move direct notes from one folder to another, then delete the empty source folder.", [
            "accountName": stringSchema(required: false),
            "sourceFolderPath": stringSchema(),
            "targetFolderPath": stringSchema(),
            "confirm": boolSchema(defaultValue: false),
            "limit": intSchema(defaultValue: 100)
        ], required: ["sourceFolderPath", "targetFolderPath"], destructive: true),
        tool("notes_link", "Create a wikilink or related section and register the link.", [
            "sourceNoteId": stringSchema(required: false),
            "sourceTitle": stringSchema(required: false),
            "targetNoteId": stringSchema(required: false),
            "targetTitle": stringSchema(required: false),
            "linkText": stringSchema(required: false),
            "mode": enumSchema(["wikilink", "related_section"]),
            "experimentalNativeUI": boolSchema(defaultValue: false)
        ], required: ["mode"]),
        tool("notes_apply_native_tags", "Experimentally append Apple Notes native tags through visual UI automation.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false),
            "tags": arraySchema(),
            "experimentalNativeUI": boolSchema(defaultValue: false)
        ], required: ["tags", "experimentalNativeUI"]),
        tool("notes_backlinks", "Return notes that link to a target note.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false)
        ], readOnly: true),
        tool("notes_extract_links", "Extract [[wikilinks]] from a note and update SQLite links.", [
            "noteId": stringSchema(required: false),
            "title": stringSchema(required: false)
        ])
    ]
}

private func tool(
    _ name: String,
    _ description: String,
    _ properties: [String: MCPValue],
    required: [String] = [],
    readOnly: Bool = false,
    destructive: Bool = false
) -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ]),
        annotations: .init(
            readOnlyHint: readOnly,
            destructiveHint: destructive,
            idempotentHint: name == "notes_create_folder",
            openWorldHint: false
        )
    )
}

private func searchSchema() -> [String: MCPValue] {
    [
        "query": stringSchema(),
        "limit": intSchema(defaultValue: 10),
        "accountName": stringSchema(required: false),
        "folderPath": stringSchema(required: false)
    ]
}

private func noteSelectionSchema() -> [String: MCPValue] {
    [
        "noteIds": arraySchema(),
        "accountName": stringSchema(required: false),
        "folderPath": stringSchema(required: false),
        "title": stringSchema(required: false),
        "titleQuery": stringSchema(required: false),
        "limit": intSchema(defaultValue: 100)
    ]
}

private func bulkMoveSchema() -> [String: MCPValue] {
    var schema = noteSelectionSchema()
    schema["targetAccountName"] = stringSchema(required: false)
    schema["targetFolderPath"] = stringSchema()
    schema["createFolderIfMissing"] = boolSchema(defaultValue: true)
    return schema
}

private func bulkArchiveSchema() -> [String: MCPValue] {
    var schema = noteSelectionSchema()
    schema["targetAccountName"] = stringSchema(required: false)
    schema["archiveFolderPath"] = stringSchema(required: false)
    schema["createFolderIfMissing"] = boolSchema(defaultValue: true)
    return schema
}

private func bulkDeleteSchema() -> [String: MCPValue] {
    var schema = noteSelectionSchema()
    schema["dryRun"] = boolSchema(defaultValue: true)
    schema["confirm"] = boolSchema(defaultValue: false)
    return schema
}

private func stringSchema(required: Bool = true) -> MCPValue {
    var object: [String: MCPValue] = ["type": .string("string")]
    if !required { object["description"] = .string("Optional") }
    return .object(object)
}

private func boolSchema(defaultValue: Bool) -> MCPValue {
    .object(["type": .string("boolean"), "default": .bool(defaultValue)])
}

private func intSchema(required: Bool = true, defaultValue: Int? = nil) -> MCPValue {
    var object: [String: MCPValue] = ["type": .string("integer")]
    if let defaultValue { object["default"] = .int(defaultValue) }
    if !required { object["description"] = .string("Optional") }
    return .object(object)
}

private func numberSchema(defaultValue: Double) -> MCPValue {
    .object(["type": .string("number"), "default": .double(defaultValue)])
}

private func arraySchema() -> MCPValue {
    .object(["type": .string("array"), "items": .object(["type": .string("string")])])
}

private func enumSchema(_ values: [String]) -> MCPValue {
    .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
}

private func resources() -> [Resource] {
    [
        Resource(name: "health", uri: "notes://health", description: "AppleNotesMCP health", mimeType: "application/json"),
        Resource(name: "schema", uri: "notes://schema", description: "SQLite schema summary", mimeType: "text/plain"),
        Resource(name: "limitations", uri: "notes://limitations", description: "Known limitations", mimeType: "text/plain"),
        Resource(name: "config", uri: "notes://config", description: "Effective configuration", mimeType: "application/json"),
        Resource(name: "stats", uri: "notes://stats", description: "Index statistics", mimeType: "application/json")
    ]
}

private func promptDefinitions() -> [Prompt] {
    [
        Prompt(name: "create_meeting_note", description: "Meeting note template"),
        Prompt(name: "create_technical_note", description: "Technical note template"),
        Prompt(name: "create_daily_log", description: "Daily log template")
    ]
}

private func promptTemplate(name: String, arguments: [String: String]) -> String? {
    switch name {
    case "create_meeting_note":
        return """
        # \(arguments["title"] ?? "Meeting Note")

        Date:
        Participants:
        Context:
        Decisions:
        Open items:
        Next steps:
        Related links:
        """
    case "create_technical_note":
        return """
        # \(arguments["title"] ?? "Technical Note")

        Problem:
        Context:
        Solution:
        Commands:
        Risks:
        References:
        Next steps:
        """
    case "create_daily_log":
        return """
        # \(arguments["date"] ?? "Daily Log")

        Summary:
        Completed:
        Blockers:
        Pending:
        Follow-ups:
        """
    default:
        return nil
    }
}

private let schemaText = """
Tables:
- metadata(key, value), including schema_version, embedding_provider, embedding_dimension, embedding_language
- notes(id, apple_note_id, account_name, folder_path, title, body_html, body_markdown, body_hash, created_at, updated_at, indexed_at, deleted_at, tags)
- folders(id, account_name, path, created_at)
- attachments(id, note_id, file_path, file_url, filename, mime_type, size_bytes, attached_as, created_at)
- links(id, source_note_id, target_note_id, target_title, link_text, link_type, created_at)
- chunks(id, note_id, chunk_index, text, text_hash, token_estimate, embedding_blob, embedding_dimension, embedding_stale, created_at, updated_at)
- notes_fts virtual table using FTS5(note_id, title, body_markdown, folder_path, tags)
- vec_chunks virtual table using embedded sqlite-vec vec0(chunk_id, embedding)
"""
