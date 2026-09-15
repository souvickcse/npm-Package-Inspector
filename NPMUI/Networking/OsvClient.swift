import Foundation

/// One advisory's affected-version info for a single npm package name. An advisory can cover
/// several related package names at once (e.g. a lodash CVE also lists lodash-es,
/// lodash.trimend, ...), each with its own fixed/last-affected version, so this is matched
/// per-package rather than assumed to be the same across the whole advisory.
private struct AffectedRange {
    let packageName: String
    let fixedVersion: String?
    let lastAffectedVersion: String?
}

private struct VulnerabilityRawDetail {
    let summary: String?
    let severity: String?
    let affected: [AffectedRange]
}

/// Checks installed packages against OSV.dev (the Open Source Vulnerabilities database) — a
/// free, unauthenticated, high-rate-limit API purpose-built for exactly this "scan my
/// dependencies" use case, so no API key or GitHub auth is needed.
struct OsvClient {
    private let session: URLSession
    private let maxConcurrency: Int

    init(session: URLSession = .shared, maxConcurrency: Int = 8) {
        self.session = session
        self.maxConcurrency = maxConcurrency
    }

    /// One batch request covers every installed package at once (that's what querybatch is for),
    /// then only the vulnerabilities actually found get a follow-up detail fetch (bounded
    /// concurrency) for their summary/severity/fix-version. Returns a map keyed by "name@version"
    /// (matching Package.id).
    func fetchVulnerabilities(for packages: [(name: String, version: String)]) async -> [String: [SecurityVulnerability]] {
        guard !packages.isEmpty, let idsByKey = await queryBatch(packages) else { return [:] }

        let allIDs = Array(Set(idsByKey.values.flatMap { $0 }))
        guard !allIDs.isEmpty else { return [:] }
        let detailsByID = await fetchDetails(for: allIDs)

        var result: [String: [SecurityVulnerability]] = [:]
        for pkg in packages {
            let key = "\(pkg.name)@\(pkg.version)"
            guard let ids = idsByKey[key] else { continue }

            let vulns = ids.compactMap { id -> SecurityVulnerability? in
                guard let raw = detailsByID[id] else { return nil }
                let match = raw.affected.first { $0.packageName == pkg.name }
                return SecurityVulnerability(
                    id: id,
                    summary: raw.summary,
                    severity: raw.severity,
                    fixedVersion: match?.fixedVersion,
                    lastAffectedVersion: match?.lastAffectedVersion
                )
            }
            if !vulns.isEmpty {
                result[key] = vulns
            }
        }
        return result
    }

    private func queryBatch(_ packages: [(name: String, version: String)]) async -> [String: [String]]? {
        guard let url = URL(string: "https://api.osv.dev/v1/querybatch") else { return nil }

        let queries = packages.map { pkg in
            ["package": ["name": pkg.name, "ecosystem": "npm"], "version": pkg.version] as [String: Any]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["queries": queries])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }

            var idsByKey: [String: [String]] = [:]
            for (index, result) in results.enumerated() where index < packages.count {
                guard let vulns = result["vulns"] as? [[String: Any]] else { continue }
                let ids = vulns.compactMap { $0["id"] as? String }
                guard !ids.isEmpty else { continue }
                let pkg = packages[index]
                idsByKey["\(pkg.name)@\(pkg.version)"] = ids
            }
            return idsByKey
        } catch {
            return nil
        }
    }

    private func fetchDetails(for ids: [String]) async -> [String: VulnerabilityRawDetail] {
        var results: [String: VulnerabilityRawDetail] = [:]
        var index = 0

        await withTaskGroup(of: (String, VulnerabilityRawDetail?).self) { group in
            func addNext() {
                guard index < ids.count else { return }
                let id = ids[index]
                index += 1
                group.addTask { (id, await self.fetchDetail(id: id)) }
            }

            for _ in 0..<min(maxConcurrency, ids.count) {
                addNext()
            }

            for await (id, detail) in group {
                if let detail {
                    results[id] = detail
                }
                addNext()
            }
        }

        return results
    }

    private func fetchDetail(id: String) async -> VulnerabilityRawDetail? {
        guard let url = URL(string: "https://api.osv.dev/v1/vulns/\(id)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let summary = json["summary"] as? String
            let severity = (json["database_specific"] as? [String: Any])?["severity"] as? String

            var affected: [AffectedRange] = []
            for entry in (json["affected"] as? [[String: Any]]) ?? [] {
                guard let package = entry["package"] as? [String: Any],
                      (package["ecosystem"] as? String) == "npm",
                      let name = package["name"] as? String else { continue }

                var fixedVersion: String?
                var lastAffectedVersion: String?
                for range in (entry["ranges"] as? [[String: Any]]) ?? [] {
                    for event in (range["events"] as? [[String: Any]]) ?? [] {
                        if let fixed = event["fixed"] as? String { fixedVersion = fixed }
                        if let lastAffected = event["last_affected"] as? String { lastAffectedVersion = lastAffected }
                    }
                }
                affected.append(AffectedRange(packageName: name, fixedVersion: fixedVersion, lastAffectedVersion: lastAffectedVersion))
            }

            return VulnerabilityRawDetail(summary: summary, severity: severity, affected: affected)
        } catch {
            return nil
        }
    }
}
