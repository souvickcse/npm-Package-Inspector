import Foundation

enum ExportFormat {
    case csv
    case json

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

enum PackageExporter {
    static func export(packages: [Package], details: [String: PackageDetail], format: ExportFormat) -> String {
        let sorted = packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch format {
        case .csv: return csv(sorted, details: details)
        case .json: return json(sorted, details: details)
        }
    }

    private static func csv(_ packages: [Package], details: [String: PackageDetail]) -> String {
        var lines = ["Name,Installed Version,Type,License,Homepage,Latest Version,Status"]
        for pkg in packages {
            let detail = details[pkg.id]
            let fields = [
                pkg.name,
                pkg.installedVersion,
                kindLabel(pkg.kind),
                detail?.license ?? "",
                detail?.homepage?.absoluteString ?? "",
                latestVersion(pkg.outdated),
                statusLabel(pkg.outdated)
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func json(_ packages: [Package], details: [String: PackageDetail]) -> String {
        let rows: [[String: String]] = packages.map { pkg in
            let detail = details[pkg.id]
            return [
                "name": pkg.name,
                "installedVersion": pkg.installedVersion,
                "type": kindLabel(pkg.kind),
                "license": detail?.license ?? "",
                "homepage": detail?.homepage?.absoluteString ?? "",
                "latestVersion": latestVersion(pkg.outdated),
                "status": statusLabel(pkg.outdated)
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func kindLabel(_ kind: DependencyKind) -> String {
        switch kind {
        case .dependency: return "dependency"
        case .devDependency: return "devDependency"
        case .transitive: return "transitive"
        }
    }

    private static func latestVersion(_ status: OutdatedStatus) -> String {
        if case .outdated(let latest) = status { return latest }
        return ""
    }

    private static func statusLabel(_ status: OutdatedStatus) -> String {
        switch status {
        case .upToDate: return "Up to date"
        case .outdated: return "Outdated"
        case .unknown, .checking, .error: return "Unknown"
        }
    }
}
