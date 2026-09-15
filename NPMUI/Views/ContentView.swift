import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ProjectViewModel()
    @State private var isTargeted = false
    @State private var selection: Package.ID?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 680, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isTargeted {
                dropOverlay
            }
        }
        .toolbar {
            if viewModel.projectFolderName != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(PackageStatusFilter.allCases) { filter in
                            Toggle(isOn: Binding(
                                get: { viewModel.activeStatusFilters.contains(filter) },
                                set: { isOn in
                                    if isOn {
                                        viewModel.activeStatusFilters.insert(filter)
                                    } else {
                                        viewModel.activeStatusFilters.remove(filter)
                                    }
                                }
                            )) {
                                Label(filter.label, systemImage: filter.icon)
                            }
                        }
                        if !viewModel.activeStatusFilters.isEmpty {
                            Divider()
                            Button("Clear Filters") { viewModel.activeStatusFilters.removeAll() }
                        }
                    } label: {
                        Label("Filter", systemImage: viewModel.activeStatusFilters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help("Filter packages by status")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Export as CSV…") { export(as: .csv) }
                        Button("Export as JSON…") { export(as: .json) }
                    } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)
                    .help("Export the package list for a license/compliance report")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder
    private var header: some View {
        if let folderName = viewModel.projectFolderName {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName)
                        .font(.headline)
                    if let lockFileType = viewModel.lockFileType {
                        let filteredCount = viewModel.filteredPackages.count
                        let totalCount = viewModel.packages.count
                        let countText = filteredCount == totalCount
                            ? "\(totalCount) packages"
                            : "\(filteredCount) of \(totalCount) packages"
                        Text("\(lockFileType.displayName) • \(countText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if viewModel.isCheckingOutdated {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isScanning {
            VStack {
                Spacer()
                ProgressView("Scanning project…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.projectFolderName == nil {
            emptyState
        } else {
            NavigationSplitView {
                PackageListView(viewModel: viewModel, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
            } detail: {
                if let selection, let package = viewModel.packages.first(where: { $0.id == selection }) {
                    PackageDetailView(package: package, viewModel: viewModel, selection: $selection)
                } else {
                    detailPlaceholder
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Select a package")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop a project folder here")
                .font(.title3)
            Text("or use Choose Folder above")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
            )
            .allowsHitTesting(false)
    }

    private func export(as format: ExportFormat) {
        Task {
            isExporting = true
            await viewModel.prepareForExport()
            isExporting = false

            let content = PackageExporter.export(packages: viewModel.packages, details: viewModel.packageDetails, format: format)

            let panel = NSSavePanel()
            let baseName = viewModel.projectFolderName ?? "packages"
            panel.nameFieldStringValue = "\(baseName)-packages.\(format.fileExtension)"
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]

            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            selection = nil
            viewModel.load(folder: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                selection = nil
                if exists, isDirectory.boolValue {
                    viewModel.load(folder: url)
                } else {
                    viewModel.load(folder: url.deletingLastPathComponent())
                }
            }
        }
        return true
    }
}
