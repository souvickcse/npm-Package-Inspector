import Foundation

/// The fields of one published version that the abbreviated packument format still includes,
/// even though it strips heavier fields like description/license — this is the same
/// low-bandwidth format already used for the outdated check, so all of this comes free.
struct PackumentVersionInfo {
    let dependencies: [String: String]
    let peerDependencies: [String: String]
    /// Peer names explicitly marked optional (peerDependenciesMeta) — npm doesn't warn about
    /// these when missing, so neither should we.
    let optionalPeerNames: Set<String>
    /// The deprecation message the maintainer set (npm publish --deprecate), if any.
    let deprecationMessage: String?
}

/// One package's lightweight registry summary: its latest version, plus per-version info for
/// every published version (covering every installed version of that name, including
/// diamond-dependency duplicates, from a single request).
struct PackumentSummary {
    let latestVersion: String?
    let versions: [String: PackumentVersionInfo]
}

struct NpmRegistryClient {
    private let session: URLSession
    private let maxConcurrency: Int

    init(session: URLSession = .shared, maxConcurrency: Int = 8) {
        self.session = session
        self.maxConcurrency = maxConcurrency
    }

    /// One call per unique package name (not per name@version — a single packument's "versions"
    /// map covers every installed version of that name, including diamond-dependency duplicates).
    func fetchPackumentSummaries(for names: [String]) async -> [String: PackumentSummary] {
        let uniqueNames = Array(Set(names))
        guard !uniqueNames.isEmpty else { return [:] }

        var results: [String: PackumentSummary] = [:]
        var index = 0

        await withTaskGroup(of: (String, PackumentSummary?).self) { group in
            func addNext() {
                guard index < uniqueNames.count else { return }
                let name = uniqueNames[index]
                index += 1
                group.addTask {
                    (name, await self.fetchPackumentSummary(name: name))
                }
            }

            for _ in 0..<min(maxConcurrency, uniqueNames.count) {
                addNext()
            }

            for await (name, summary) in group {
                if let summary {
                    results[name] = summary
                }
                addNext()
            }
        }

        return results
    }

    /// Fetches description/license/homepage for one package's installed version, for the detail
    /// pane. Separate from the bulk summary call since this needs the full (heavier) document and
    /// is only ever called for the single currently-selected package.
    func fetchDetail(name: String, version: String) async -> PackageDetail? {
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://registry.npmjs.org/\(encodedName)") else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let versions = json["versions"] as? [String: Any]
            let latestTag = (json["dist-tags"] as? [String: Any])?["latest"] as? String
            let versionDoc = (versions?[version] as? [String: Any])
                ?? latestTag.flatMap { versions?[$0] as? [String: Any] }

            let description = (versionDoc?["description"] as? String) ?? (json["description"] as? String)
            let license = extractLicense(versionDoc?["license"]) ?? extractLicense(json["license"])
            let homepageString = (versionDoc?["homepage"] as? String) ?? (json["homepage"] as? String)

            return PackageDetail(
                description: description,
                license: license,
                homepage: homepageString.flatMap(URL.init(string:))
            )
        } catch {
            return nil
        }
    }

    /// Bulk variant of `fetchDetail`, for operations (like export) that need every installed
    /// package's description/license/homepage at once rather than lazily per-selection.
    func fetchDetails(for packages: [(name: String, version: String)]) async -> [String: PackageDetail] {
        var results: [String: PackageDetail] = [:]
        var index = 0

        await withTaskGroup(of: (String, PackageDetail?).self) { group in
            func addNext() {
                guard index < packages.count else { return }
                let pkg = packages[index]
                index += 1
                group.addTask {
                    ("\(pkg.name)@\(pkg.version)", await self.fetchDetail(name: pkg.name, version: pkg.version))
                }
            }

            for _ in 0..<min(maxConcurrency, packages.count) {
                addNext()
            }

            for await (key, detail) in group {
                if let detail {
                    results[key] = detail
                }
                addNext()
            }
        }

        return results
    }

    private func extractLicense(_ value: Any?) -> String? {
        if let license = value as? String { return license }
        if let dict = value as? [String: Any] { return dict["type"] as? String }
        return nil
    }

    private func fetchPackumentSummary(name: String) async -> PackumentSummary? {
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://registry.npmjs.org/\(encodedName)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let latest = (json["dist-tags"] as? [String: Any])?["latest"] as? String
            let versions = (json["versions"] as? [String: Any]) ?? [:]

            var versionInfos: [String: PackumentVersionInfo] = [:]
            for (version, value) in versions {
                guard let entry = value as? [String: Any] else { continue }
                let peerMeta = entry["peerDependenciesMeta"] as? [String: Any] ?? [:]
                let optionalPeerNames = Set(peerMeta.compactMap { name, meta -> String? in
                    ((meta as? [String: Any])?["optional"] as? Bool) == true ? name : nil
                })
                versionInfos[version] = PackumentVersionInfo(
                    dependencies: (entry["dependencies"] as? [String: String]) ?? [:],
                    peerDependencies: (entry["peerDependencies"] as? [String: String]) ?? [:],
                    optionalPeerNames: optionalPeerNames,
                    deprecationMessage: entry["deprecated"] as? String
                )
            }

            return PackumentSummary(latestVersion: latest, versions: versionInfos)
        } catch {
            return nil
        }
    }
}
