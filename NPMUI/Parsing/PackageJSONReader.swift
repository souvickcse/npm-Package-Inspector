import Foundation

struct PackageJSONReader {
    /// Maps each direct dependency name to its declared semver range (e.g. "^4.17.21"),
    /// which is enough to disambiguate diamond dependencies for the yarn parser.
    struct Classification {
        let dependencies: [String: String]
        let devDependencies: [String: String]
    }

    func read(fileURL: URL) -> Classification {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Classification(dependencies: [:], devDependencies: [:])
        }
        return Classification(
            dependencies: stringDict(json["dependencies"]),
            devDependencies: stringDict(json["devDependencies"])
        )
    }

    private func stringDict(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let range = value as? String {
                result[key] = range
            }
        }
        return result
    }
}
