import Foundation

struct IndexedNote: Sendable {
    var id: String
    var appleNoteId: String?
    var accountName: String?
    var folderPath: String?
    var title: String
    var bodyHTML: String?
    var bodyMarkdown: String?
    var bodyHash: String?
    var createdAt: String?
    var updatedAt: String?
    var indexedAt: String?
    var deletedAt: String?
    var tags: [String]
}

struct FolderRecord: Sendable {
    let id: String
    let accountName: String
    let path: String
    let createdAt: String
}

struct FolderSummary: Sendable {
    let id: String
    let accountName: String
    let path: String
    let parentId: String?
    let childCount: Int
    let noteCount: Int
    let createdAt: String
}

struct SearchResult: Sendable {
    let score: Double
    let title: String
    let snippet: String
    let noteId: String
    let accountName: String?
    let folderPath: String?
    let lexicalScore: Double?
    let vectorScore: Double?
    let combinedScore: Double?
    let rankReason: String?
    let chunkIndex: Int?

    init(
        score: Double,
        title: String,
        snippet: String,
        noteId: String,
        accountName: String?,
        folderPath: String?,
        lexicalScore: Double? = nil,
        vectorScore: Double? = nil,
        combinedScore: Double? = nil,
        rankReason: String? = nil,
        chunkIndex: Int? = nil
    ) {
        self.score = score
        self.title = title
        self.snippet = snippet
        self.noteId = noteId
        self.accountName = accountName
        self.folderPath = folderPath
        self.lexicalScore = lexicalScore
        self.vectorScore = vectorScore
        self.combinedScore = combinedScore
        self.rankReason = rankReason
        self.chunkIndex = chunkIndex
    }
}

struct LinkRecord: Sendable {
    let id: String
    let sourceNoteId: String
    let targetNoteId: String?
    let targetTitle: String?
    let linkText: String?
    let linkType: String
    let createdAt: String
}

struct AttachmentRecord: Sendable {
    let id: String
    let noteId: String
    let filePath: String
    let fileURL: String
    let filename: String
    let mimeType: String?
    let sizeBytes: Int64
    let attachedAs: String
    let createdAt: String
}
