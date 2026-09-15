import Foundation

@MainActor
final class ProjectViewModel: ObservableObject {
    @Published private(set) var projectFolderName: String?
    @Published private(set) var lockFileType: LockFileType?
    @Published private(set) var packages: [Package] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingOutdated = false
    @Published private(set) var errorMessage: String?
    @Published var searchText: String = ""
    /// Empty means no status filtering (show everything); otherwise a package must match at
    /// least one active filter (OR, not AND — e.g. "Deprecated or Vulnerable" both selected
    /// shows a package that's either).
    @Published var activeStatusFilters: Set<PackageStatusFilter> = []

    /// Keyed by Package.id ("name@version") so cached details never get shown against the
    /// wrong installed version if a project is rescanned.
    @Published private(set) var packageDetails: [String: PackageDetail] = [:]
    @Published private(set) var detailLoadFailed: Set<String> = []
    private var detailLoadingIDs: Set<String> = []

    /// This package's own declared dependencies (name -> range), from the registry, for the
    /// specific installed version. Package.id -> {depName: range}.
    @Published private(set) var declaredDependencies: [String: [String: String]] = [:]
    /// Reverse index: package name -> ids of installed packages that declare it as a dependency.
    @Published private(set) var dependentsByName: [String: [Package.ID]] = [:]
    /// Package.id -> the deprecation message for that exact installed version, when npm shows one.
    @Published private(set) var deprecationMessages: [String: String] = [:]
    /// Package.id -> (peer name, declared range) pairs the package needs but that aren't
    /// installed anywhere in the project. Excludes peers marked optional via peerDependenciesMeta.
    @Published private(set) var missingPeerDependencies: [String: [(name: String, range: String)]] = [:]

    /// Package.id -> known vulnerabilities affecting that exact installed version, from OSV.dev.
    @Published private(set) var vulnerabilities: [String: [SecurityVulnerability]] = [:]
    @Published private(set) var isCheckingVulnerabilities = false

    private let registryClient = NpmRegistryClient()
    private let osvClient = OsvClient()
    private var outdatedCheckTask: Task<Void, Never>?
    private var vulnerabilityCheckTask: Task<Void, Never>?

    var filteredPackages: [Package] {
        packages.filter { pkg in
            (searchText.isEmpty || pkg.name.localizedCaseInsensitiveContains(searchText)) && matchesActiveStatusFilters(pkg)
        }
    }

    private func matchesActiveStatusFilters(_ package: Package) -> Bool {
        guard !activeStatusFilters.isEmpty else { return true }
        return activeStatusFilters.contains { filter in
            switch filter {
            case .outdated:
                if case .outdated = package.outdated { return true }
                return false
            case .deprecated:
                return deprecationMessages[package.id] != nil
            case .vulnerable:
                return !(vulnerabilities[package.id]?.isEmpty ?? true)
            case .missingPeer:
                return !(missingPeerDependencies[package.id]?.isEmpty ?? true)
            }
        }
    }

    func package(withID id: Package.ID) -> Package? {
        packages.first { $0.id == id }
    }

    func load(folder url: URL) {
        outdatedCheckTask?.cancel()
        vulnerabilityCheckTask?.cancel()
        errorMessage = nil
        isScanning = true
        projectFolderName = url.lastPathComponent
        packageDetails = [:]
        detailLoadFailed = []
        detailLoadingIDs = []
        declaredDependencies = [:]
        dependentsByName = [:]
        deprecationMessages = [:]
        missingPeerDependencies = [:]
        vulnerabilities = [:]

        Task {
            defer { isScanning = false }
            do {
                let scanned = try ProjectScanner().scan(folderURL: url)
                lockFileType = scanned.lockFileType
                packages = scanned.packages
                loadRegistryGraph()
                loadVulnerabilities()
            } catch {
                lockFileType = nil
                packages = []
                errorMessage = error.localizedDescription
            }
        }
    }

    /// One automatic pass on load that both flags outdated packages and builds the dependency
    /// graph (declared deps per package, and the reverse "who depends on this" index), all from
    /// the same lightweight bulk registry call.
    private func loadRegistryGraph() {
        let names = packages.map(\.name)
        guard !names.isEmpty else { return }

        for index in packages.indices {
            packages[index].outdated = .checking
        }
        isCheckingOutdated = true

        outdatedCheckTask = Task {
            let summaries = await registryClient.fetchPackumentSummaries(for: names)
            guard !Task.isCancelled else { return }

            var declared: [String: [String: String]] = [:]
            var dependents: [String: [Package.ID]] = [:]
            var deprecations: [String: String] = [:]
            var missingPeers: [String: [(name: String, range: String)]] = [:]
            let installedNames = Set(packages.map(\.name))

            for index in packages.indices {
                let pkg = packages[index]
                guard let summary = summaries[pkg.name] else {
                    packages[index].outdated = .error
                    continue
                }

                if let latest = summary.latestVersion {
                    packages[index].outdated = SemVer.isNewer(latest, than: pkg.installedVersion)
                        ? .outdated(latest: latest)
                        : .upToDate
                } else {
                    packages[index].outdated = .error
                }

                guard let info = summary.versions[pkg.installedVersion] else { continue }

                declared[pkg.id] = info.dependencies
                for depName in info.dependencies.keys {
                    dependents[depName, default: []].append(pkg.id)
                }

                deprecations[pkg.id] = info.deprecationMessage

                let missing = info.peerDependencies
                    .filter { name, _ in !installedNames.contains(name) && !info.optionalPeerNames.contains(name) }
                    .map { (name: $0.key, range: $0.value) }
                    .sorted { $0.name < $1.name }
                if !missing.isEmpty {
                    missingPeers[pkg.id] = missing
                }
            }

            declaredDependencies = declared
            dependentsByName = dependents
            deprecationMessages = deprecations
            missingPeerDependencies = missingPeers
            isCheckingOutdated = false
        }
    }

    /// Runs independently of `loadRegistryGraph` (different API, no shared data) so a slow or
    /// failed vulnerability check never blocks the outdated/dependency-graph results, or vice versa.
    private func loadVulnerabilities() {
        guard !packages.isEmpty else { return }
        isCheckingVulnerabilities = true
        let targets = packages.map { (name: $0.name, version: $0.installedVersion) }

        vulnerabilityCheckTask = Task {
            let result = await osvClient.fetchVulnerabilities(for: targets)
            guard !Task.isCancelled else { return }
            vulnerabilities = result
            isCheckingVulnerabilities = false
        }
    }

    /// Ensures every installed package has cached description/license/homepage before an export,
    /// since license is normally only fetched lazily when a package is selected — an export
    /// meant for a compliance report with mostly-blank license columns wouldn't be very useful.
    func prepareForExport() async {
        let missing = packages.filter { packageDetails[$0.id] == nil && !detailLoadFailed.contains($0.id) }
        guard !missing.isEmpty else { return }

        let targets = missing.map { (name: $0.name, version: $0.installedVersion) }
        let results = await registryClient.fetchDetails(for: targets)

        for pkg in missing {
            if let detail = results[pkg.id] {
                packageDetails[pkg.id] = detail
            } else {
                detailLoadFailed.insert(pkg.id)
            }
        }
    }

    func loadDetail(for package: Package) {
        guard packageDetails[package.id] == nil,
              !detailLoadFailed.contains(package.id),
              !detailLoadingIDs.contains(package.id) else { return }

        detailLoadingIDs.insert(package.id)
        Task {
            let detail = await registryClient.fetchDetail(name: package.name, version: package.installedVersion)
            detailLoadingIDs.remove(package.id)
            if let detail {
                packageDetails[package.id] = detail
            } else {
                detailLoadFailed.insert(package.id)
            }
        }
    }
}
