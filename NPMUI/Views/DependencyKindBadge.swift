import SwiftUI

struct DependencyKindBadge: View {
    let kind: DependencyKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }

    // A solid, opaque fill rather than a translucent tint: a light background pill blends into
    // a selected sidebar row's blue highlight (macOS's "vibrant" selection blending), losing all
    // contrast. Opaque color + white text stays legible regardless of what's behind it.
    private var color: Color {
        switch kind {
        case .dependency: return .blue
        case .devDependency: return .orange
        case .transitive: return .gray
        }
    }
}

func npmURL(for packageName: String) -> URL? {
    guard let encoded = packageName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    return URL(string: "https://www.npmjs.com/package/\(encoded)")
}
