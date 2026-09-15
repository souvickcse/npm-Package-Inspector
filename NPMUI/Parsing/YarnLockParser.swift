import Foundation

/// Parses yarn.lock, a custom (non-YAML) format: unindented header lines list
/// one or more comma-separated "name@range" specifiers resolving to the same
/// package, followed by an indented block containing a "version" line.
struct YarnLockParser: LockFileParser {
    func parse(fileURL: URL) throws -> [LockFileEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw LockFileParsingError.fileReadFailed(fileURL)
        }

        var results: [LockFileEntry] = []
        var currentSpecs: [(name: String, version: String)] = []
        var currentVersion: String?

        func flush() {
            if let version = currentVersion {
                let byName = Dictionary(grouping: currentSpecs, by: \.name)
                for (name, specs) in byName {
                    results.append(LockFileEntry(
                        name: name,
                        version: version,
                        isDev: false,
                        requestedRanges: specs.map(\.version)
                    ))
                }
            }
            currentSpecs = []
            currentVersion = nil
        }

        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.isEmpty || rawLine.hasPrefix("#") { continue }

            let isIndented = rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")

            if !isIndented {
                flush()
                guard rawLine.hasSuffix(":") else { continue }
                let header = String(rawLine.dropLast())
                currentSpecs = header
                    .components(separatedBy: ", ")
                    .compactMap { spec -> (name: String, version: String)? in
                        var s = spec.trimmingCharacters(in: .whitespaces)
                        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                            s = String(s.dropFirst().dropLast())
                        }
                        return PackageSpec.split(s)
                    }
            } else {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("version ") {
                    var value = String(trimmed.dropFirst("version ".count)).trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    currentVersion = value
                }
            }
        }
        flush()
        return results
    }
}
