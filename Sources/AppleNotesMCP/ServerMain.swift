import Foundation
import MCP

public func runAppleNotesMCPServer() async throws {
    let config = try AppConfig.load()
    let logger = try AppLogger(path: config.logPath, level: config.logLevel)
    let store = try SQLiteStore(
        path: config.databasePath,
        logger: logger,
        embeddingDimension: config.embeddingDimension,
        embeddingProvider: config.embeddingProvider,
        embeddingLanguage: config.embeddingLanguage
    )
    let service = NotesService(config: config, logger: logger, store: store)

    let server = Server(
        name: "AppleNotesMCP",
        version: AppConfig.version,
        instructions: "Local-first MCP server for Apple Notes. Use manual sync before searching existing notes.",
        capabilities: .init(
            prompts: .init(listChanged: false),
            resources: .init(subscribe: false, listChanged: false),
            tools: .init(listChanged: false)
        )
    )
    await registerMCPHandlers(server: server, service: service)

    let transport = StdioTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
}
