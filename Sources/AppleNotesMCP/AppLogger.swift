import Foundation

enum AppLogLevel: Int, Sendable {
    case debug = 0
    case info = 1
    case error = 2

    init(_ raw: String) {
        switch raw.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        default: self = .error
        }
    }
}

extension AppLogLevel: CustomStringConvertible {
    var description: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        }
    }
}

final class AppLogger: @unchecked Sendable {
    private let path: String
    private let level: AppLogLevel
    private let lock = NSLock()
    private let maxBytes: Int

    init(path: String, level: String, maxBytes: Int = 1_048_576) throws {
        self.path = path
        self.level = AppLogLevel(level)
        self.maxBytes = max(1, maxBytes)
        try ensureParentDirectory(for: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    func debug(_ operation: String, fields: [String: String] = [:]) {
        write(.debug, operation: operation, fields: fields)
    }

    func info(_ operation: String, fields: [String: String] = [:]) {
        write(.info, operation: operation, fields: fields)
    }

    func error(_ operation: String, fields: [String: String] = [:]) {
        write(.error, operation: operation, fields: fields)
    }

    private func write(_ messageLevel: AppLogLevel, operation: String, fields: [String: String]) {
        guard messageLevel.rawValue >= level.rawValue else { return }
        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded()
        let sanitized = sanitizeLogFields(fields)

        let kv = sanitized
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = "\(isoNow()) level=\(messageLevel) operation=\(sanitizeLogToken(operation)) \(kv)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes
        else { return }

        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    private func sanitizeLogFields(_ fields: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in fields {
            let lower = key.lowercased()
            if isSafeNoteIdentifierField(lower) {
                sanitized[key] = sanitizeLogToken(truncatedId(value), maxLength: 12)
            } else if isSafeCountField(lower) {
                sanitized[key] = sanitizeIntegerToken(value)
            } else if isSafeExactField(lower) {
                sanitized[key] = sanitizeLogToken(value)
            }
        }
        return sanitized
    }

    private func isSafeExactField(_ lowerKey: String) -> Bool {
        [
            "code",
            "dimension",
            "duration_ms",
            "embeddingdimension",
            "embeddinglanguage",
            "embeddingprovider",
            "language",
            "mode",
            "provider"
        ].contains(lowerKey)
    }

    private func isSafeCountField(_ lowerKey: String) -> Bool {
        lowerKey == "count"
            || lowerKey.hasSuffix("_count")
            || lowerKey.hasSuffix("count")
            || [
                "deletedmarked",
                "indexed",
                "rebuildfts",
                "rebuildvectors",
                "seen",
                "skipped"
            ].contains(lowerKey)
    }

    private func isSafeNoteIdentifierField(_ lowerKey: String) -> Bool {
        lowerKey == "noteid"
            || lowerKey == "applenoteid"
            || lowerKey == "sourcenoteid"
            || lowerKey == "targetnoteid"
    }

    private func sanitizeIntegerToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(trimmed) != nil else { return "0" }
        return trimmed
    }

    private func sanitizeLogToken(_ value: String, maxLength: Int = 80) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
                || scalar == "-"
                || scalar == "."
            {
                return Character(scalar)
            }
            return "_"
        }
        return String(String(scalars).prefix(maxLength))
    }
}
