import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let projects: ProjectStore
    let runners: RunnerManager
    let launchAtLogin: LaunchAtLoginController

    @Published private(set) var showsRunnerLogs = true
    @Published private(set) var pendingProjectIDs: Set<UUID> = []

    private var didStartMonitoring = false
    private var didStartRunner = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        projects = ProjectStore()
        runners = RunnerManager()
        launchAtLogin = LaunchAtLoginController()
        observeRunnerScan()
    }

    init(
        projects: ProjectStore,
        runners: RunnerManager,
        launchAtLogin: LaunchAtLoginController
    ) {
        self.projects = projects
        self.runners = runners
        self.launchAtLogin = launchAtLogin
        observeRunnerScan()
    }

    func applicationDidFinishLaunching() {
        guard !didStartMonitoring else {
            return
        }

        didStartMonitoring = true
        runners.startMonitoring()
    }

    func toggleRunnerLogs() {
        setRunnerLogsVisible(!showsRunnerLogs)
    }

    func setRunnerLogsVisible(_ isVisible: Bool) {
        showsRunnerLogs = isVisible
    }

    @discardableResult
    func addProject(directoryURL: URL) -> RunnerProject {
        let project = projects.add(
            directoryURL: directoryURL,
            isServed: !runners.isRunning
        )
        guard !pendingProjectIDs.contains(project.id) else {
            return project
        }
        if runners.isRunning {
            guard !project.isServed else {
                return project
            }
            pendingProjectIDs.insert(project.id)
            runners.addDirectory(project.directoryURL) { [weak self] succeeded in
                self?.pendingProjectIDs.remove(project.id)
                if succeeded {
                    self?.projects.setIsServed(true, for: project.id)
                }
            }
        } else {
            projects.setIsServed(true, for: project.id)
            startRunner()
        }
        return projects.projects.first(where: { $0.id == project.id }) ?? project
    }

    func setIsServed(_ isServed: Bool, for project: RunnerProject) {
        guard project.isServed != isServed else {
            return
        }
        guard !pendingProjectIDs.contains(project.id) else {
            return
        }
        if runners.isRunning {
            pendingProjectIDs.insert(project.id)
            let updateStore: (Bool) -> Void = { [weak self] succeeded in
                self?.pendingProjectIDs.remove(project.id)
                if succeeded {
                    self?.projects.setIsServed(isServed, for: project.id)
                }
            }
            if isServed {
                runners.addDirectory(project.directoryURL, completion: updateStore)
            } else {
                runners.removeDirectory(project.directoryURL, completion: updateStore)
            }
        } else {
            projects.setIsServed(isServed, for: project.id)
            if isServed {
                startRunner()
            }
        }
    }

    func startRunner() {
        runners.start(directories: servedDirectories)
    }

    func stopRunner() {
        runners.stop()
    }

    func remove(_ project: RunnerProject) {
        guard !pendingProjectIDs.contains(project.id) else {
            return
        }
        if project.isServed, runners.isRunning {
            pendingProjectIDs.insert(project.id)
            runners.removeDirectory(project.directoryURL) { [weak self] succeeded in
                self?.pendingProjectIDs.remove(project.id)
                if succeeded {
                    self?.projects.remove(id: project.id)
                }
            }
        } else {
            projects.remove(id: project.id)
        }
    }

    private var servedDirectories: [URL] {
        projects.projects.filter(\.isServed).map(\.directoryURL)
    }

    private func observeRunnerScan() {
        runners.$hasCompletedInitialScan
            .sink { [weak self] hasCompletedInitialScan in
                self?.startRunnerAfterInitialScan(hasCompletedInitialScan)
            }
            .store(in: &cancellables)

        runners.$servedDirectoryPaths
            .compactMap { $0 }
            .sink { [weak self] servedDirectoryPaths in
                self?.syncProjects(with: servedDirectoryPaths)
            }
            .store(in: &cancellables)
    }

    private func syncProjects(with servedDirectoryPaths: Set<String>) {
        for path in servedDirectoryPaths {
            projects.add(
                directoryURL: URL(fileURLWithPath: path, isDirectory: true),
                isServed: true
            )
        }

        for project in projects.projects where !pendingProjectIDs.contains(project.id) {
            let normalizedPath = project.directoryURL.standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            projects.setIsServed(servedDirectoryPaths.contains(normalizedPath), for: project.id)
        }
    }

    private func startRunnerAfterInitialScan(_ hasCompletedInitialScan: Bool) {
        guard hasCompletedInitialScan, !didStartRunner else {
            return
        }

        didStartRunner = true
        guard !runners.isRunning else {
            return
        }
        startRunner()
    }
}
