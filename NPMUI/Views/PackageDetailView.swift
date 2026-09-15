import SwiftUI
import AppKit

struct PackageDetailView: View {
    let package: Package
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var selection: Package.ID?
    @State private var didCopyCommand = false

    private var detail: PackageDetail? {
        viewModel.packageDetails[package.id]
    }

    private var isLoading: Bool {
        detail == nil && !viewModel.detailLoadFailed.contains(package.id)
    }

    /// This package's own declared dependencies, cross-referenced against what's actually
    /// installed in the project (rather than just the range the registry declares).
    private var dependencyRefs: [DependencyRef] {
        let ranges = viewModel.declaredDependencies[package.id] ?? [:]
        return ranges.map { name, range in
            DependencyRef(name: name, range: range, installed: viewModel.packages.filter { $0.name == name })
        }.sorted { $0.name < $1.name }
    }

    /// The command to run to update this package to latest, in the syntax matching this
    /// project's package manager and whether it's a dependency or devDependency. Not applicable
    /// to transitive packages, since those aren't something you'd install directly — npm/yarn/
    /// pnpm would just reinstall it as a top-level dependency instead of updating it in place.
    private func updateCommand(latest: String) -> String? {
        guard package.kind != .transitive, let lockFileType = viewModel.lockFileType else { return nil }
        let isDev = package.kind == .devDependency
        switch lockFileType {
        case .npm:
            return isDev
                ? "npm install \(package.name)@\(latest) --save-dev"
                : "npm install \(package.name)@\(latest)"
        case .yarn:
            return isDev
                ? "yarn add \(package.name)@\(latest) --dev"
                : "yarn add \(package.name)@\(latest)"
        case .pnpm:
            return isDev
                ? "pnpm add \(package.name)@\(latest) --save-dev"
                : "pnpm add \(package.name)@\(latest)"
        }
    }

    /// Other installed packages that declare this package's name as a dependency. Matched by
    /// name only (not exact range-satisfaction) — see note on `dependentsByName`.
    private var dependents: [Package] {
        (viewModel.dependentsByName[package.name] ?? [])
            .filter { $0 != package.id }
            .compactMap(viewModel.package(withID:))
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()

                if let vulns = viewModel.vulnerabilities[package.id], !vulns.isEmpty {
                    securityBanner(vulns)
                }

                if let message = viewModel.deprecationMessages[package.id] {
                    deprecationBanner(message)
                }

                if let missing = viewModel.missingPeerDependencies[package.id], !missing.isEmpty {
                    peerDependencyBanner(missing)
                }

                if let detail, let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                }

                detailsSection

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                } else {
                    if viewModel.detailLoadFailed.contains(package.id) {
                        Text("Couldn't load description/license/homepage from the npm registry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !dependencyRefs.isEmpty {
                        Divider()
                        graphSection(title: "Dependencies", rows: dependencyRefs.map { ref in
                            GraphRow(
                                id: ref.name,
                                name: ref.name,
                                detail: ref.installed.first.map { "v\($0.installedVersion)" } ?? ref.range,
                                detailColor: ref.installed.isEmpty ? .secondary : .primary,
                                targetID: ref.installed.first?.id
                            )
                        })
                    }

                    if !dependents.isEmpty {
                        Divider()
                        graphSection(title: "Dependents", rows: dependents.map { pkg in
                            GraphRow(id: pkg.id, name: pkg.name, detail: "v\(pkg.installedVersion)", detailColor: .secondary, targetID: pkg.id)
                        })
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 260)
        .task(id: package.id) {
            viewModel.loadDetail(for: package)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(package.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let url = npmURL(for: package.name) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("View \(package.name) on npmjs.com")
                }
            }
            DependencyKindBadge(kind: package.kind)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledRow(label: "Installed", value: package.installedVersion)

            switch package.outdated {
            case .outdated(let latest):
                LabeledRow(label: "Latest", value: latest, valueColor: .orange)
                if let command = updateCommand(latest: latest) {
                    LabeledRow(label: "Update") {
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Button {
                                copyToClipboard(command)
                            } label: {
                                Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy command")
                        }
                    }
                }
            case .upToDate:
                LabeledRow(label: "Latest", value: "Up to date", valueColor: .green)
            default:
                EmptyView()
            }

            if let detail {
                if let license = detail.license, !license.isEmpty {
                    LabeledRow(label: "License", value: license)
                }
                if let homepage = detail.homepage {
                    LabeledRow(label: "Homepage") {
                        Link(homepage.absoluteString, destination: homepage)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func securityBanner(_ vulnerabilities: [SecurityVulnerability]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text(vulnerabilities.count == 1 ? "1 known vulnerability" : "\(vulnerabilities.count) known vulnerabilities")
                    .font(.callout.weight(.semibold))
            }
            ForEach(vulnerabilities) { vuln in
                Link(destination: vuln.url) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 6) {
                            if let severity = vuln.severity {
                                Text(severity.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            Text(vuln.summary ?? vuln.id)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        if let versionNote = vuln.versionNote {
                            Text(versionNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func deprecationBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Deprecated")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func peerDependencyBanner(_ missing: [(name: String, range: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.orange)
                Text(missing.count == 1 ? "1 missing peer dependency" : "\(missing.count) missing peer dependencies")
                    .font(.callout.weight(.semibold))
            }
            ForEach(missing, id: \.name) { peer in
                HStack {
                    if let url = npmURL(for: peer.name) {
                        Link(peer.name, destination: url)
                            .font(.system(.callout, design: .monospaced))
                    } else {
                        Text(peer.name)
                            .font(.system(.callout, design: .monospaced))
                    }
                    Spacer()
                    Text(peer.range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopyCommand = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyCommand = false
        }
    }

    private func graphSection(title: String, rows: [GraphRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                Button {
                    if let targetID = row.targetID {
                        selection = targetID
                    }
                } label: {
                    HStack {
                        Text(row.name)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(row.detailColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.targetID == nil)
            }
        }
    }
}

private struct DependencyRef {
    let name: String
    let range: String
    /// Installed instance(s) of this dependency name in the project; more than one means a
    /// diamond dependency, in which case the first is shown (a range-satisfaction check to pick
    /// the exact one would need a full semver range parser, which felt like overkill here).
    let installed: [Package]
}

private struct GraphRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let detailColor: Color
    let targetID: Package.ID?
}

private struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content
        }
    }
}

private extension LabeledRow where Content == Text {
    init(label: String, value: String, valueColor: Color = .primary) {
        self.init(label: label) {
            Text(value)
                .font(.callout)
                .foregroundColor(valueColor)
        }
    }
}
