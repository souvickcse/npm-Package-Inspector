import Foundation

enum LockFileType: String {
    case npm = "package-lock.json"
    case yarn = "yarn.lock"
    case pnpm = "pnpm-lock.yaml"

    var displayName: String {
        switch self {
        case .npm: return "npm"
        case .yarn: return "Yarn"
        case .pnpm: return "pnpm"
        }
    }
}
