import Foundation

/// Parses package-lock.json, handling both the legacy nested-tree format
/// (lockfileVersion 1) and the flat "packages" map format (lockfileVersion 2/3).
struct NpmLockParser: LockFileParser {
    func parse(fileURL: URL) throws -> [LockFileEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw LockFileParsingError.fileReadFailed(fileURL)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LockFileParsingError.invalidFormat("root is not a JSON object")
        }

        var results: [LockFileEntry] = []

        if let packages = json["packages"] as? [String: Any] {
            for (path, value) in packages {
                guard !path.isEmpty, let entry = value as? [String: Any],
                      let version = entry["version"] as? String,
                      let name = packageName(fromNodeModulesPath: path) else { continue }
                let isDev = (entry["dev"] as? Bool) ?? false
                let isTopLevel = path.components(separatedBy: "node_modules/").count - 1 == 1
                results.append(LockFileEntry(name: name, version: version, isDev: isDev, isTopLevel: isTopLevel))
            }
        } else if let dependencies = json["dependencies"] as? [String: Any] {
            collectV1(dependencies, isTopLevel: true, into: &results)
        } else {
            throw LockFileParsingError.invalidFormat("no \"packages\" or \"dependencies\" key found")
        }

        return results
    }

    private func packageName(fromNodeModulesPath path: String) -> String? {
        guard let range = path.range(of: "node_modules/", options: .backwards) else { return nil }
        let tail = String(path[range.upperBound...])
        if tail.hasPrefix("@") {
            let comps = tail.split(separator: "/", maxSplits: 2)
            guard comps.count >= 2 else { return tail }
            return "\(comps[0])/\(comps[1])"
        }
        return tail.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    private func collectV1(_ dependencies: [String: Any], isTopLevel: Bool, into results: inout [LockFileEntry]) {
        for (name, value) in dependencies {
            guard let entry = value as? [String: Any], let version = entry["version"] as? String else { continue }
            let isDev = (entry["dev"] as? Bool) ?? false
            results.append(LockFileEntry(name: name, version: version, isDev: isDev, isTopLevel: isTopLevel))
            if let nested = entry["dependencies"] as? [String: Any] {
                collectV1(nested, isTopLevel: false, into: &results)
            }
        }
    }
}
