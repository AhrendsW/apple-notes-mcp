import Foundation
import NaturalLanguage

protocol EmbeddingProvider: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

struct EmbeddingProfile: Equatable, Sendable {
    let provider: String
    let dimension: Int
    let language: String

    static func current(dimension: Int) -> EmbeddingProfile {
        EmbeddingProfile(
            provider: HashingEmbeddingProvider.providerName,
            dimension: dimension,
            language: HashingEmbeddingProvider.language
        )
    }
}

struct EmbeddingProviderResolution: Sendable {
    let profile: EmbeddingProfile
    let warnings: [String]
}

struct NoopEmbeddingProvider: EmbeddingProvider {
    static let providerName = "NoopEmbeddingProvider"
    static let language = "und"

    let dimension: Int

    func embed(_ text: String) async throws -> [Float] {
        throw NotesError.typed(
            code: "embedding_provider_unavailable",
            message: "Embeddings are disabled or no local provider is available.",
            details: ["suggestion": "Use notes_search_fts or notes_search_hybrid."]
        )
    }
}

final class NaturalLanguageEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    static let providerName = "NaturalLanguageEmbeddingProvider"

    let language: String
    let dimension: Int

    private let lock = NSLock()
    private var cachedEmbedding: NLEmbedding?

    init(language: String, dimension: Int) {
        self.language = language
        self.dimension = dimension
    }

    func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Float](repeating: 0, count: dimension)
        }

        let embedding = try embeddingInstance()
        guard let vector = embedding.vector(for: text) else {
            throw NotesError.typed(
                code: "embedding_vector_failed",
                message: "NaturalLanguage could not produce a sentence embedding.",
                details: ["provider": Self.providerName, "language": language]
            )
        }
        let floats = vector.map(Float.init)
        guard floats.count == dimension else {
            throw NotesError.typed(
                code: "embedding_dimension_mismatch",
                message: "NaturalLanguage returned an unexpected embedding dimension.",
                details: [
                    "provider": Self.providerName,
                    "language": language,
                    "expected": "\(dimension)",
                    "actual": "\(floats.count)"
                ]
            )
        }
        return floats
    }

    private func embeddingInstance() throws -> NLEmbedding {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEmbedding { return cachedEmbedding }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(language)) else {
            throw NotesError.typed(
                code: "embedding_provider_unavailable",
                message: "Apple NaturalLanguage sentence embeddings are unavailable for language '\(language)'.",
                details: ["provider": Self.providerName, "language": language]
            )
        }
        cachedEmbedding = embedding
        return embedding
    }

    static func profileIfAvailable(language rawLanguage: String) -> EmbeddingProfile? {
        let language = EmbeddingProviderResolver.normalizedLanguage(rawLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(language)) else {
            return nil
        }
        return EmbeddingProfile(
            provider: providerName,
            dimension: embedding.dimension,
            language: language
        )
    }
}

struct HashingEmbeddingProvider: EmbeddingProvider {
    static let providerName = "HashingEmbeddingProvider"
    static let language = "und"

    let dimension: Int

    func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let tokens = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        guard !tokens.isEmpty else { return vector }
        for token in tokens {
            let hash = stableHash(token)
            let bucket = Int(UInt64(hash.prefix(8), radix: 16) ?? 0) % dimension
            vector[bucket] += 1
        }
        return normalize(vector)
    }

    private func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

enum EmbeddingProviderResolver {
    static let defaultProvider = NaturalLanguageEmbeddingProvider.providerName
    static let defaultLanguage = "pt"
    static let fallbackNaturalLanguage = "en"
    static let fallbackHashingDimension = 384

    static func resolve(
        requestedProvider: String,
        requestedLanguage: String,
        requestedDimension: Int
    ) -> EmbeddingProviderResolution {
        let provider = canonicalProviderName(requestedProvider)
        let dimension = max(16, requestedDimension)

        switch provider {
        case NaturalLanguageEmbeddingProvider.providerName:
            return resolveNaturalLanguage(
                requestedLanguage: requestedLanguage,
                fallbackDimension: dimension
            )
        case HashingEmbeddingProvider.providerName:
            return EmbeddingProviderResolution(
                profile: EmbeddingProfile(
                    provider: HashingEmbeddingProvider.providerName,
                    dimension: dimension,
                    language: HashingEmbeddingProvider.language
                ),
                warnings: []
            )
        case NoopEmbeddingProvider.providerName:
            return EmbeddingProviderResolution(
                profile: EmbeddingProfile(
                    provider: NoopEmbeddingProvider.providerName,
                    dimension: dimension,
                    language: NoopEmbeddingProvider.language
                ),
                warnings: []
            )
        default:
            return EmbeddingProviderResolution(
                profile: EmbeddingProfile(
                    provider: HashingEmbeddingProvider.providerName,
                    dimension: dimension,
                    language: HashingEmbeddingProvider.language
                ),
                warnings: [
                    "Unknown embeddingProvider '\(requestedProvider)'; using \(HashingEmbeddingProvider.providerName)."
                ]
            )
        }
    }

    static func canonicalProviderName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "",
             "natural_language",
             "natural-language",
             "natural_language_embedding",
             "naturallanguage",
             "naturallanguageembeddingprovider",
             "nl",
             "apple_naturallanguage":
            return NaturalLanguageEmbeddingProvider.providerName
        case "hashing",
             "hashing_embedding",
             "hashingembeddingprovider",
             "local",
             "localembeddingprovider":
            return HashingEmbeddingProvider.providerName
        case "noop",
             "none",
             "disabled",
             "noopembeddingprovider":
            return NoopEmbeddingProvider.providerName
        default:
            return value
        }
    }

    static func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultLanguage }
        return trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? defaultLanguage
    }

    private static func resolveNaturalLanguage(
        requestedLanguage: String,
        fallbackDimension: Int
    ) -> EmbeddingProviderResolution {
        let preferred = normalizedLanguage(requestedLanguage)
        let candidates = unique([preferred, fallbackNaturalLanguage])

        for language in candidates {
            if let profile = NaturalLanguageEmbeddingProvider.profileIfAvailable(language: language) {
                let warnings = language == preferred
                    ? []
                    : ["NaturalLanguage sentence embeddings are unavailable for '\(preferred)'; using '\(language)'."]
                return EmbeddingProviderResolution(profile: profile, warnings: warnings)
            }
        }

        return EmbeddingProviderResolution(
            profile: EmbeddingProfile(
                provider: HashingEmbeddingProvider.providerName,
                dimension: fallbackDimension,
                language: HashingEmbeddingProvider.language
            ),
            warnings: [
                "No Apple NaturalLanguage sentence embedding is available for '\(preferred)' or '\(fallbackNaturalLanguage)'; using \(HashingEmbeddingProvider.providerName)."
            ]
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

actor EmbeddingService {
    private let config: AppConfig
    private var provider: (any EmbeddingProvider)?

    init(config: AppConfig) {
        self.config = config
    }

    func embed(_ text: String) async throws -> [Float] {
        let provider = try providerInstance()
        return try await provider.embed(text)
    }

    func isEnabled() -> Bool {
        config.embeddingsEnabled
    }

    func providerName() -> String {
        config.embeddingsEnabled ? config.embeddingProvider : NoopEmbeddingProvider.providerName
    }

    private func providerInstance() throws -> any EmbeddingProvider {
        if let provider { return provider }
        let created: any EmbeddingProvider
        if !config.embeddingsEnabled || config.embeddingProvider == NoopEmbeddingProvider.providerName {
            created = NoopEmbeddingProvider(dimension: config.embeddingDimension)
        } else if config.embeddingProvider == NaturalLanguageEmbeddingProvider.providerName {
            created = NaturalLanguageEmbeddingProvider(
                language: config.embeddingLanguage,
                dimension: config.embeddingDimension
            )
        } else {
            created = HashingEmbeddingProvider(dimension: config.embeddingDimension)
        }
        provider = created
        return created
    }
}

func vectorToBlob(_ vector: [Float]) -> Data {
    var data = Data(capacity: vector.count * MemoryLayout<Float>.size)
    for value in vector {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

func blobToVector(_ data: Data) -> [Float] {
    guard data.count % MemoryLayout<UInt32>.size == 0 else { return [] }
    return stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
        var bits: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &bits) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + 4))
        }
        return Float(bitPattern: UInt32(littleEndian: bits))
    }
}
