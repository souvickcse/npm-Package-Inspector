import Foundation

struct LockFileEntry {
    let name: String
    let version: String
    let isDev: Bool
    /// True when the lock file's own structure confirms this occurrence is the version
    /// satisfying a root-level requirement (npm: shallowest node_modules path; pnpm: matches
    /// the top-level dependencies/devDependencies block). Used to disambiguate "diamond
    /// dependencies" where the same package resolves to multiple versions.
    var isTopLevel: Bool = false
    /// yarn only: the verbatim semver ranges (e.g. "^4.17.21") from the lock header(s) that
    /// resolve to this entry, used to match against package.json's declared range instead.
    var requestedRanges: [String] = []
}

protocol LockFileParser {
    func parse(fileURL: URL) throws -> [LockFileEntry]
}

enum LockFileParsingError: Error, LocalizedError {
    case fileReadFailed(URL)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let url):
            return "Could not read \(url.lastPathComponent)."
        case .invalidFormat(let detail):
            return "Could not parse lock file: \(detail)"
        }
    }
}

/// Splits a bare "name@version" (or "@scope/name@version") specifier into its parts.
/// Shared by the yarn and pnpm parsers, whose lock keys both use this shape.
enum PackageSpec {
    static func split(_ spec: String) -> (name: String, version: String)? {
        guard !spec.isEmpty else { return nil }
        let searchStart = spec.index(after: spec.startIndex)
        guard let atRange = spec.range(of: "@", range: searchStart..<spec.endIndex) else { return nil }
        let name = String(spec[spec.startIndex..<atRange.lowerBound])
        let version = String(spec[atRange.upperBound...])
        guard !version.isEmpty else { return nil }
        return (name, version)
    }
}
