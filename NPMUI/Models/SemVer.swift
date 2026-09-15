import Foundation

enum SemVer {
    static func isNewer(_ candidate: String, than base: String) -> Bool {
        guard let c = components(candidate), let b = components(base) else {
            return candidate != base
        }

        for i in 0..<3 where c[i] != b[i] {
            return c[i] > b[i]
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }
}
