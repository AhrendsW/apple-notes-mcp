import Foundation

struct AppConfig: Codable, Sendable {
    var defaultAccount: String
    var allowOnMyMac: Bool
    var databasePath: String
    var logPath: String
    var logLevel: String
    var embeddingsEnabled: Bool
    var maxEmbeddingConcurrency: Int
    var maxSyncConcurrency: Int
    var syncLockPath: String
    var embeddingProvider: String
    var embeddingLanguage: String
    var embeddingDimension: Int
    var embeddingWarnings: [String]

    static let version = "0.1.0"
    static let swiftVersionTarget = "6.3.1"

    enum CodingKeys: String, CodingKey {
        case defaultAccount
        case allowOnMyMac
        case databasePath
        case logPath
        case logLevel
        case embeddingsEnabled
        case maxEmbeddingConcurrency
        case maxSyncConcurrency
        case syncLockPath
        case embeddingProvider
        case embeddingLanguage
        case embeddingDimension
    }

    init(
        defaultAccount: String,
        allowOnMyMac: Bool,
        databasePath: String,
        logPath: String,
        logLevel: String,
        embeddingsEnabled: Bool,
        maxEmbeddingConcurrency: Int,
        maxSyncConcurrency: Int,
        syncLockPath: String,
        embeddingProvider: String = EmbeddingProviderResolver.defaultProvider,
        embeddingLanguage: String = EmbeddingProviderResolver.defaultLanguage,
        embeddingDimension: Int = EmbeddingProviderResolver.fallbackHashingDimension,
        embeddingWarnings: [String] = []
    ) {
        self.defaultAccount = defaultAccount
        self.allowOnMyMac = allowOnMyMac
        self.databasePath = databasePath
        self.logPath = logPath
        self.logLevel = logLevel
        self.embeddingsEnabled = embeddingsEnabled
        self.maxEmbeddingConcurrency = maxEmbeddingConcurrency
        self.maxSyncConcurrency = maxSyncConcurrency
        self.syncLockPath = syncLockPath
        self.embeddingProvider = embeddingProvider
        self.embeddingLanguage = embeddingLanguage
        self.embeddingDimension = embeddingDimension
        self.embeddingWarnings = embeddingWarnings
    }

    init(from decoder: Decoder) throws {
        let defaults = AppConfig.defaults()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultAccount: try container.decodeIfPresent(String.self, forKey: .defaultAccount) ?? defaults.defaultAccount,
            allowOnMyMac: try container.decodeIfPresent(Bool.self, forKey: .allowOnMyMac) ?? defaults.allowOnMyMac,
            databasePath: try container.decodeIfPresent(String.self, forKey: .databasePath) ?? defaults.databasePath,
            logPath: try container.decodeIfPresent(String.self, forKey: .logPath) ?? defaults.logPath,
            logLevel: try container.decodeIfPresent(String.self, forKey: .logLevel) ?? defaults.logLevel,
            embeddingsEnabled: try container.decodeIfPresent(Bool.self, forKey: .embeddingsEnabled) ?? defaults.embeddingsEnabled,
            maxEmbeddingConcurrency: try container.decodeIfPresent(Int.self, forKey: .maxEmbeddingConcurrency) ?? defaults.maxEmbeddingConcurrency,
            maxSyncConcurrency: try container.decodeIfPresent(Int.self, forKey: .maxSyncConcurrency) ?? defaults.maxSyncConcurrency,
            syncLockPath: try container.decodeIfPresent(String.self, forKey: .syncLockPath) ?? defaults.syncLockPath,
            embeddingProvider: try container.decodeIfPresent(String.self, forKey: .embeddingProvider) ?? defaults.embeddingProvider,
            embeddingLanguage: try container.decodeIfPresent(String.self, forKey: .embeddingLanguage) ?? defaults.embeddingLanguage,
            embeddingDimension: try container.decodeIfPresent(Int.self, forKey: .embeddingDimension) ?? defaults.embeddingDimension
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultAccount, forKey: .defaultAccount)
        try container.encode(allowOnMyMac, forKey: .allowOnMyMac)
        try container.encode(databasePath, forKey: .databasePath)
        try container.encode(logPath, forKey: .logPath)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(embeddingsEnabled, forKey: .embeddingsEnabled)
        try container.encode(maxEmbeddingConcurrency, forKey: .maxEmbeddingConcurrency)
        try container.encode(maxSyncConcurrency, forKey: .maxSyncConcurrency)
        try container.encode(syncLockPath, forKey: .syncLockPath)
        try container.encode(embeddingProvider, forKey: .embeddingProvider)
        try container.encode(embeddingLanguage, forKey: .embeddingLanguage)
        try container.encode(embeddingDimension, forKey: .embeddingDimension)
    }

    static func load() throws -> AppConfig {
        let defaultConfig = AppConfig.defaults()
        let base = URL(fileURLWithPath: defaultConfig.databasePath)
            .deletingLastPathComponent()
            .path
        let configPath = ProcessInfo.processInfo.environment["APPLE_NOTES_MCP_CONFIG"]
            ?? "\(base)/config.json"
        guard FileManager.default.fileExists(atPath: expandTilde(configPath)) else {
            return defaultConfig.normalized()
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: expandTilde(configPath)))
        let loaded = try JSONDecoder().decode(AppConfig.self, from: data)
        return loaded.normalized()
    }

    static func defaults() -> AppConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = "\(home)/Library/Application Support/AppleNotesMCP"
        return AppConfig(
            defaultAccount: "iCloud",
            allowOnMyMac: true,
            databasePath: "\(base)/index.sqlite",
            logPath: "\(home)/Library/Logs/AppleNotesMCP/server.log",
            logLevel: "error",
            embeddingsEnabled: true,
            maxEmbeddingConcurrency: 1,
            maxSyncConcurrency: 1,
            syncLockPath: "\(base)/sync.lock",
            embeddingProvider: EmbeddingProviderResolver.defaultProvider,
            embeddingLanguage: EmbeddingProviderResolver.defaultLanguage,
            embeddingDimension: EmbeddingProviderResolver.fallbackHashingDimension
        )
    }

    func normalized() -> AppConfig {
        var copy = self
        copy.databasePath = expandTilde(copy.databasePath)
        copy.logPath = expandTilde(copy.logPath)
        copy.syncLockPath = expandTilde(copy.syncLockPath)
        copy.maxEmbeddingConcurrency = max(1, copy.maxEmbeddingConcurrency)
        copy.maxSyncConcurrency = max(1, copy.maxSyncConcurrency)
        let resolved = EmbeddingProviderResolver.resolve(
            requestedProvider: copy.embeddingProvider,
            requestedLanguage: copy.embeddingLanguage,
            requestedDimension: copy.embeddingDimension
        )
        copy.embeddingProvider = resolved.profile.provider
        copy.embeddingLanguage = resolved.profile.language
        copy.embeddingDimension = resolved.profile.dimension
        copy.embeddingWarnings = resolved.warnings
        return copy
    }

    var embeddingProfile: EmbeddingProfile {
        EmbeddingProfile(
            provider: embeddingProvider,
            dimension: embeddingDimension,
            language: embeddingLanguage
        )
    }
}

func expandTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func ensureParentDirectory(for path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
    )
}
