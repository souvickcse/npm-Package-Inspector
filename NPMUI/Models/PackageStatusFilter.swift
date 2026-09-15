import Foundation

enum PackageStatusFilter: String, CaseIterable, Identifiable {
    case outdated
    case deprecated
    case vulnerable
    case missingPeer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .outdated: return "Update Available"
        case .deprecated: return "Deprecated"
        case .vulnerable: return "Vulnerable"
        case .missingPeer: return "Missing Peer Dependency"
        }
    }

    var icon: String {
        switch self {
        case .outdated: return "arrow.up.circle"
        case .deprecated: return "exclamationmark.triangle.fill"
        case .vulnerable: return "exclamationmark.shield.fill"
        case .missingPeer: return "puzzlepiece.extension.fill"
        }
    }
}
