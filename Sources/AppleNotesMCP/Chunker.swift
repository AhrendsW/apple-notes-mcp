import Foundation

struct NoteChunk: Sendable {
    let id: String
    let noteId: String
    let index: Int
    let text: String
    let textHash: String
    let tokenEstimate: Int
}

struct Chunker: Sendable {
    let minTokensForChunking = 180
    let chunkSize = 700
    let overlap = 100

    func chunks(noteId: String, text: String) -> [NoteChunk] {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        guard tokens.count > minTokensForChunking else {
            let chunkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunkText.isEmpty else { return [] }
            return [
                NoteChunk(
                    id: UUID().uuidString,
                    noteId: noteId,
                    index: 0,
                    text: chunkText,
                    textHash: stableHash(chunkText),
                    tokenEstimate: max(1, tokens.count)
                )
            ]
        }

        var results: [NoteChunk] = []
        var start = 0
        var index = 0
        while start < tokens.count {
            let end = min(tokens.count, start + chunkSize)
            let chunkText = tokens[start..<end].joined(separator: " ")
            results.append(
                NoteChunk(
                    id: UUID().uuidString,
                    noteId: noteId,
                    index: index,
                    text: chunkText,
                    textHash: stableHash(chunkText),
                    tokenEstimate: end - start
                )
            )
            if end == tokens.count { break }
            start = max(end - overlap, start + 1)
            index += 1
        }
        return results
    }
}

