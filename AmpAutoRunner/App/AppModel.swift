import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let projects: ProjectStore
    let runners: RunnerManager
    let launchAtLogin: LaunchAtLoginController

    @Published private(set) var showsRunnerLogs = true

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
        let project = projects.add(directoryURL: directoryURL)
        projects.setIsServed(true, for: project.id)
        if runners.isRunning {
            runners.addDirectory(project.directoryURL)
        } else {
            startRunner()
        }
        return projects.projects.first(where: { $0.id == project.id }) ?? project
    }

    func setIsServed(_ isServed: Bool, for project: RunnerProject) {
        projects.setIsServed(isServed, for: project.id)
        if isServed {
            if runners.isRunning {
                runners.addDirectory(project.directoryURL)
            } else {
                startRunner()
            }
        } else if runners.isRunning {
            runners.removeDirectory(project.directoryURL)
        }
    }

    func startRunner() {
        runners.start(directories: servedDirectories)
    }

    func stopRunner() {
        runners.stop()
    }

    func remove(_ project: RunnerProject) {
        if project.isServed, runners.isRunning {
            runners.removeDirectory(project.directoryURL)
        }
        projects.remove(id: project.id)
    }

    private var servedDirectories: [URL] {
        projects.projects.filter(\.isServed).map(\.directoryURL)
    }

    private func observeRunnerScan() {
        runners.$hasCompletedInitialScan
            .sink { [weak self] _ in
                self?.startRunnerAfterInitialScan()
            }
            .store(in: &cancellables)
    }

    private func startRunnerAfterInitialScan() {
        guard runners.hasCompletedInitialScan, !didStartRunner else {
            return
        }

        didStartRunner = true
        startRunner()
    }
}
