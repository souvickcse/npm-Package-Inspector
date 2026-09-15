import Foundation

enum DependencyKind {
    case dependency
    case devDependency
    case transitive

    var label: String {
        switch self {
        case .dependency: return "dep"
        case .devDependency: return "dev"
        case .transitive: return "transitive"
        }
    }
}

enum OutdatedStatus: Equatable {
    case unknown
    case checking
    case upToDate
    case outdated(latest: String)
    case error
}

struct Package: Identifiable {
    let id: String
    let name: String
    let installedVersion: String
    var kind: DependencyKind
    var outdated: OutdatedStatus = .unknown
}
