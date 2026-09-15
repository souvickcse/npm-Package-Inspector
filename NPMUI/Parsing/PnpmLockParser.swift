import Foundation
import Yams

/// Parses pnpm-lock.yaml's top-level "packages" map. Keys look like
/// "/foo@1.2.3" or "foo@1.2.3" (older/newer pnpm versions), optionally with a
/// peer-dependency suffix like "(react@18.0.0)", which is stripped before parsing.
struct PnpmLockParser: LockFileParser {
    func parse(fileURL: URL) throws -> [LockFileEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw LockFileParsingError.fileReadFailed(fileURL)
        }

        let yaml: Any?
        do {
            yaml = try Yams.load(yaml: content)
        } catch {
            throw LockFileParsingError.invalidFormat("YAML parse error: \(error.localizedDescription)")
        }

        guard let root = stringKeyedDict(yaml) else {
            throw LockFileParsingError.invalidFormat("root is not a mapping")
        }
        guard let packages = stringKeyedDict(root["packages"]) else {
            throw LockFileParsingError.invalidFormat("no \"packages\" key found")
        }

        // pnpm-lock.yaml's own top-level "dependencies"/"devDependencies" blocks already state
        // the exact resolved version for each direct requirement, so we can self-confirm the
        // "top level" entry for a diamond dependency without needing package.json at all.
        let directVersions = topLevelDirectVersions(root: root)

        var results: [LockFileEntry] = []
        for (key, value) in packages {
            guard let parsed = parseKey(key) else { continue }
            let isDev = stringKeyedDict(value)?["dev"] as? Bool ?? false
            let isTopLevel = directVersions[parsed.name] == parsed.version
            results.append(LockFileEntry(name: parsed.name, version: parsed.version, isDev: isDev, isTopLevel: isTopLevel))
        }
        return results
    }

    private func topLevelDirectVersions(root: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for blockKey in ["dependencies", "devDependencies"] {
            guard let block = stringKeyedDict(root[blockKey]) else { continue }
            for (name, value) in block {
                guard let version = stringKeyedDict(value)?["version"] as? String else { continue }
                result[name] = stripPeerSuffix(version)
            }
        }
        return result
    }

    private func parseKey(_ key: String) -> (name: String, version: String)? {
        var stripped = key
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        return PackageSpec.split(stripPeerSuffix(stripped))
    }

    private func stripPeerSuffix(_ value: String) -> String {
        guard let parenIndex = value.firstIndex(of: "(") else { return value }
        return String(value[value.startIndex..<parenIndex])
    }

    private func stringKeyedDict(_ value: Any?) -> [String: Any]? {
        guard let dict = value as? [AnyHashable: Any] else { return nil }
        var result: [String: Any] = [:]
        for (key, val) in dict {
            if let k = key as? String {
                result[k] = val
            }
        }
        return result
    }
}
