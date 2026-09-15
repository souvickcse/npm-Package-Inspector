import SwiftUI

struct PackageListView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var selection: Package.ID?

    private var sortedPackages: [Package] {
        viewModel.filteredPackages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(sortedPackages, selection: $selection) { pkg in
            PackageRow(
                package: pkg,
                isSelected: selection == pkg.id,
                isDeprecated: viewModel.deprecationMessages[pkg.id] != nil,
                vulnerabilityCount: viewModel.vulnerabilities[pkg.id]?.count ?? 0,
                missingPeerCount: viewModel.missingPeerDependencies[pkg.id]?.count ?? 0
            )
        }
        .searchable(text: $viewModel.searchText, prompt: "Filter packages")
    }
}

private struct PackageRow: View {
    let package: Package
    /// macOS mutes non-adaptive colors (like plain .orange/.green) on a selected sidebar row for
    /// its "vibrant" blending effect, which kills contrast against the blue highlight. Swapping
    /// to white when selected keeps the outdated/up-to-date indicator legible either way.
    let isSelected: Bool
    let isDeprecated: Bool
    let vulnerabilityCount: Int
    let missingPeerCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if vulnerabilityCount > 0 {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white : .red)
                        .help(vulnerabilityCount == 1 ? "1 known vulnerability" : "\(vulnerabilityCount) known vulnerabilities")
                }
                if isDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white : .red)
                        .help("Deprecated")
                }
                if missingPeerCount > 0 {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white : .orange)
                        .help(missingPeerCount == 1 ? "1 missing peer dependency" : "\(missingPeerCount) missing peer dependencies")
                }
                Text(package.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                DependencyKindBadge(kind: package.kind)
            }

            HStack(spacing: 8) {
                Text("v\(package.installedVersion)")
                    .foregroundStyle(.secondary)
                outdatedView(package.outdated)
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func outdatedView(_ status: OutdatedStatus) -> some View {
        switch status {
        case .unknown, .error:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.mini)
        case .upToDate:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .green)
        case .outdated(let latest):
            Text("→ \(latest)")
                .foregroundStyle(isSelected ? .white : .orange)
        }
    }
}
