import Combine
import Foundation

@MainActor
final class AppModel {
    let projects: ProjectStore
    let runners: RunnerManager
    let launchAtLogin: LaunchAtLoginController

    private var didStartMonitoring = false
    private var didAutoStartProjects = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        projects = ProjectStore()
        runners = RunnerManager()
        launchAtLogin = LaunchAtLoginController()
        observeRunningRunners()
    }

    init(
        projects: ProjectStore,
        runners: RunnerManager,
        launchAtLogin: LaunchAtLoginController
    ) {
        self.projects = projects
        self.runners = runners
        self.launchAtLogin = launchAtLogin
        observeRunningRunners()
    }

    func applicationDidFinishLaunching() {
        guard !didStartMonitoring else {
            return
        }

        didStartMonitoring = true
        runners.startMonitoring()
    }

    func setAutoStarts(_ autoStarts: Bool, for project: RunnerProject) {
        projects.setStartsAutomatically(autoStarts, for: project.id)
        if autoStarts {
            migrateOrStart(project)
        }
    }

    func autoStarts(_ runner: RunningRunner) -> Bool {
        project(for: runner)?.startsAutomatically == true
    }

    func isManaged(_ runner: RunningRunner) -> Bool {
        project(for: runner) != nil
    }

    var activeRunnerCount: Int {
        projects.projects.filter { runners.state(for: $0) == .running }.count
    }

    @discardableResult
    func addProject(directoryURL: URL) -> RunnerProject {
        let project = projects.add(directoryURL: directoryURL)
        projects.setStartsAutomatically(true, for: project.id)
        migrateOrStart(project)
        return project
    }

    func setAutoStarts(_ autoStarts: Bool, for runner: RunningRunner) {
        if autoStarts {
            guard let directoryURL = runner.directoryURL else {
                return
            }

            let project = projects.add(directoryURL: directoryURL, runnerID: runner.runnerID)
            projects.setStartsAutomatically(true, for: project.id)
            runners.migrate(runner, to: project)
            return
        }

        guard let project = project(for: runner) else {
            return
        }
        projects.setStartsAutomatically(false, for: project.id)
    }

    @discardableResult
    func setRunnerID(_ runnerID: String, for project: RunnerProject) -> String {
        guard
            runners.runningRunner(for: project) == nil,
            runners.state(for: project) != .starting,
            runners.state(for: project) != .stopping
        else {
            return project.runnerID
        }

        return projects.setRunnerID(runnerID, for: project.id) ?? project.runnerID
    }

    func stop(_ runner: RunningRunner) {
        runners.stop(runner)
    }

    func remove(_ project: RunnerProject) {
        runners.stop(projectID: project.id)
        projects.remove(id: project.id)
    }

    private func observeRunningRunners() {
        runners.$runningRunners
            .sink { [weak self] runningRunners in
                self?.autoStartSavedProjects(afterDiscovering: runningRunners)
            }
            .store(in: &cancellables)
    }

    private func autoStartSavedProjects(afterDiscovering runningRunners: [RunningRunner]) {
        guard runners.hasCompletedInitialScan, !didAutoStartProjects else {
            return
        }

        didAutoStartProjects = true
        for project in projects.projects where
            project.startsAutomatically
                && !runningRunners.contains(where: {
                    $0.path == project.path || $0.runnerID == project.runnerID
                })
        {
            runners.start(project, automatically: true)
        }
    }

    private func migrateOrStart(
        _ project: RunnerProject,
        among runningRunners: [RunningRunner]? = nil,
        automatically: Bool = false
    ) {
        let candidates = runningRunners ?? runners.runningRunners
        let runningRunner = candidates.first { $0.path == project.path }
            ?? candidates.first { $0.runnerID == project.runnerID }

        if let runningRunner {
            if !runners.isOwned(runningRunner) {
                runners.migrate(runningRunner, to: project)
            }
            return
        }

        runners.start(project, automatically: automatically)
    }

    func project(for runner: RunningRunner) -> RunnerProject? {
        projects.projects.first { project in
            project.path == runner.path || project.runnerID == runner.runnerID
        }
    }
}
