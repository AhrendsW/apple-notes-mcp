import Foundation

extension NotesService {
    func applyNativeTagsData(_ args: [String: MCPValue]) async throws -> MCPValue {
        guard args.bool("experimentalNativeUI", default: false) else {
            throw NotesError.typed(
                code: "invalid_params",
                message: "notes_apply_native_tags requires experimentalNativeUI=true."
            )
        }
        var note = try resolveNote(noteId: args.string("noteId"), title: args.string("title"))
        let tags = try normalizedNativeTags(args["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        guard !tags.isEmpty else {
            throw NotesError.typed(code: "invalid_params", message: "tags must contain at least one tag.")
        }

        let nativeResult: MCPValue
        do {
            nativeResult = try await attemptNativeTags(note: note, tags: tags)
        } catch let error as NotesError {
            logger.error(
                "notes_apply_native_tags_native_ui",
                fields: experimentalUIFallbackLogFields(
                    noteId: note.id,
                    code: error.code,
                    reason: error.details["reason"],
                    fallback: "sqlite_metadata"
                )
            )
            nativeResult = experimentalUIFallbackValue(
                code: error.code,
                reason: error.details["reason"],
                fallback: "sqlite_metadata"
            )
        }
        note.tags = Array(Set(note.tags + tags)).sorted()
        note.indexedAt = isoNow()
        try await index(note, includeEmbeddings: config.embeddingsEnabled)

        return .object([
            "noteId": .string(note.id),
            "appleNoteId": note.appleNoteId.map(MCPValue.string) ?? .null,
            "tagCount": .int(tags.count),
            "experimentalNativeUI": nativeResult,
            "indexed": .bool(true)
        ])
    }

    func experimentalUIFallbackLogFields(
        noteId: String,
        code: String,
        reason: String?,
        fallback: String
    ) -> [String: String] {
        var fields = [
            "noteId": noteId,
            "code": code,
            "nativeApplied": "false",
            "fallback": fallback
        ]
        if let reason, !reason.isEmpty {
            fields["reason"] = reason
        }
        return fields
    }

    func experimentalUIFallbackValue(code: String, reason: String?, fallback: String) -> MCPValue {
        var object: [String: MCPValue] = [
            "experimentalNativeUI": .bool(true),
            "nativeApplied": .bool(false),
            "code": .string(code),
            "fallback": .string(fallback),
            "limitation": .string("Apple Notes native tags and note links are not reliably writable through supported automation; MCP stored the fallback in its SQLite index.")
        ]
        if let reason, !reason.isEmpty {
            object["reason"] = .string(reason)
        }
        return .object(object)
    }

    func attemptNativeTags(note: IndexedNote, tags: [String]) async throws -> MCPValue {
        guard let appleId = note.appleNoteId else {
            throw NotesError.typed(
                code: "note_not_found",
                message: "Cannot apply native tags without appleNoteId."
            )
        }
        let normalized = try normalizedNativeTags(tags)
        guard !normalized.isEmpty else {
            throw NotesError.typed(code: "invalid_params", message: "tags must contain at least one tag.")
        }
        return try await jxa.run(
            operation: "notes_apply_native_tags",
            scriptBody: Self.scriptAppendNativeTagsUI,
            input: .object([
                "appleNoteId": .string(appleId),
                "tags": .array(normalized.map(MCPValue.string))
            ])
        )
    }

    func attemptNativeNoteLink(source: IndexedNote, target: IndexedNote, mode: String) async throws -> MCPValue {
        guard let sourceAppleId = source.appleNoteId else {
            throw NotesError.typed(
                code: "note_not_found",
                message: "Cannot apply native note link without source appleNoteId."
            )
        }
        return try await jxa.run(
            operation: "notes_link_native_ui",
            scriptBody: Self.scriptAppendNativeNoteLinkUI,
            input: .object([
                "sourceAppleNoteId": .string(sourceAppleId),
                "targetAppleNoteId": target.appleNoteId.map(MCPValue.string) ?? .null,
                "targetTitle": .string(target.title),
                "mode": .string(mode)
            ])
        )
    }

    private func normalizedNativeTags(_ tags: [String]) throws -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()
        for rawTag in tags {
            let tag = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !tag.isEmpty else { continue }
            guard tag.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw NotesError.typed(
                    code: "invalid_params",
                    message: "Native Apple Notes tags must be a single word; use hyphens or underscores instead of spaces."
                )
            }
            guard tag.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw NotesError.typed(
                    code: "invalid_params",
                    message: "Native Apple Notes tags in experimental UI mode may contain only letters, numbers, hyphens, and underscores."
                )
            }
            if seen.insert(tag).inserted {
                normalized.append(tag)
            }
        }
        return normalized
    }
}
