import Foundation

struct ScannedProject {
    let folderURL: URL
    let lockFileType: LockFileType
    let packages: [Package]
}

enum ProjectScanError: Error, LocalizedError {
    case noLockFileFound
    case parsingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noLockFileFound:
            return "No package-lock.json, yarn.lock, or pnpm-lock.yaml found in this folder."
        case .parsingFailed(let error):
            return error.localizedDescription
        }
    }
}

struct ProjectScanner {
    private let candidates: [(LockFileType, LockFileParser)] = [
        (.npm, NpmLockParser()),
        (.yarn, YarnLockParser()),
        (.pnpm, PnpmLockParser())
    ]

    func scan(folderURL: URL) throws -> ScannedProject {
        for (type, parser) in candidates {
            let lockURL = folderURL.appendingPathComponent(type.rawValue)
            guard FileManager.default.fileExists(atPath: lockURL.path) else { continue }

            do {
                let entries = try parser.parse(fileURL: lockURL)
                let classification = PackageJSONReader().read(fileURL: folderURL.appendingPathComponent("package.json"))
                let packages = Self.buildPackages(from: entries, classification: classification)
                return ScannedProject(folderURL: folderURL, lockFileType: type, packages: packages)
            } catch {
                throw ProjectScanError.parsingFailed(error)
            }
        }
        throw ProjectScanError.noLockFileFound
    }

    private static func buildPackages(
        from entries: [LockFileEntry],
        classification: PackageJSONReader.Classification
    ) -> [Package] {
        var seen = Set<String>()
        let deduped = entries.filter { seen.insert("\($0.name)@\($0.version)").inserted }
        let groupsByName = Dictionary(grouping: deduped, by: \.name)
        let confirmedDirectVersion = confirmedDirectVersions(groupsByName: groupsByName, classification: classification)

        let packages = deduped.map { entry in
            Package(
                id: "\(entry.name)@\(entry.version)",
                name: entry.name,
                installedVersion: entry.version,
                kind: kind(for: entry, groupSize: groupsByName[entry.name]?.count ?? 1, confirmedDirectVersion: confirmedDirectVersion, classification: classification)
            )
        }

        return packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A package name can resolve to more than one installed version at once (a "diamond
    /// dependency": your project depends directly on lodash@4, but some other package pulls in
    /// lodash@3 transitively). When that happens, only ONE of those versions is the one actually
    /// satisfying the root project's own package.json requirement, and only that one should carry
    /// the dep/dev badge. This resolves which version that is, per name, whenever the lock file
    /// gives us enough signal to tell (npm's node_modules path depth, pnpm's own top-level
    /// dependencies block, or a yarn lock header's range matching package.json's exactly).
    private static func confirmedDirectVersions(
        groupsByName: [String: [LockFileEntry]],
        classification: PackageJSONReader.Classification
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (name, group) in groupsByName where group.count > 1 {
            guard let range = classification.dependencies[name] ?? classification.devDependencies[name] else { continue }
            if let match = group.first(where: { $0.isTopLevel || $0.requestedRanges.contains(range) }) {
                result[name] = match.version
            }
        }
        return result
    }

    private static func kind(
        for entry: LockFileEntry,
        groupSize: Int,
        confirmedDirectVersion: [String: String],
        classification: PackageJSONReader.Classification
    ) -> DependencyKind {
        let isDependency = classification.dependencies[entry.name] != nil
        let isDevDependency = classification.devDependencies[entry.name] != nil
        guard isDependency || isDevDependency else {
            return entry.isDev ? .devDependency : .transitive
        }

        let directKind: DependencyKind = isDependency ? .dependency : .devDependency
        guard groupSize > 1, let confirmedVersion = confirmedDirectVersion[entry.name] else {
            // Only one resolved version for this name (the common case), or no format-specific
            // signal was available to disambiguate — fall back to the simple name-based match.
            return directKind
        }
        return entry.version == confirmedVersion ? directKind : (entry.isDev ? .devDependency : .transitive)
    }
}
