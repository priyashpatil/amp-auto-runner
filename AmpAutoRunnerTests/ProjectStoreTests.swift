import Darwin
import XCTest
@testable import AmpAutoRunner

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testRunnerListAndLogsCannotBothBeHidden() {
        let model = AppModel()

        XCTAssertTrue(model.showsRunnerList)
        XCTAssertFalse(model.showsRunnerLogs)

        model.setRunnerListVisible(false)

        XCTAssertFalse(model.showsRunnerList)
        XCTAssertTrue(model.showsRunnerLogs)

        model.setRunnerLogsVisible(false)

        XCTAssertTrue(model.showsRunnerList)
        XCTAssertFalse(model.showsRunnerLogs)
    }

    func testProjectsPersistAndDuplicatePathsAreIgnored() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let directoryURL = URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)

        let firstProject = store.add(directoryURL: directoryURL)
        let duplicateProject = store.add(directoryURL: directoryURL)
        let restoredStore = ProjectStore(defaults: defaults)

        XCTAssertEqual(firstProject.id, duplicateProject.id)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(restoredStore.projects, [firstProject])
    }

    func testAdoptingRunningProjectPreservesItsRunnerID() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let directoryURL = URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)
        let originalProject = store.add(directoryURL: directoryURL)

        let adoptedProject = store.add(directoryURL: directoryURL, runnerID: "existing-runner")
        let restoredStore = ProjectStore(defaults: defaults)

        XCTAssertEqual(adoptedProject.id, originalProject.id)
        XCTAssertEqual(adoptedProject.runnerID, "existing-runner")
        XCTAssertEqual(restoredStore.projects, [adoptedProject])
    }

    func testAdoptingDuplicateRunnerIDsCreatesUniqueSavedIDs() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let firstProject = store.add(
            directoryURL: URL(fileURLWithPath: "/tmp/first"),
            runnerID: "shared-runner"
        )
        let secondProject = store.add(
            directoryURL: URL(fileURLWithPath: "/tmp/second"),
            runnerID: "shared-runner"
        )

        XCTAssertEqual(firstProject.runnerID, "shared-runner")
        XCTAssertEqual(secondProject.runnerID, "shared-runner-2")
        XCTAssertEqual(Set(store.projects.map(\.runnerID)).count, 2)
    }

    func testDuplicatePersistedRunnerIDsAreRepaired() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedProjects = [
            RunnerProject(path: "/tmp/first", runnerID: "shared-runner"),
            RunnerProject(path: "/tmp/second", runnerID: "shared-runner"),
        ]
        defaults.set(try JSONEncoder().encode(storedProjects), forKey: "runnerProjects")

        let store = ProjectStore(defaults: defaults)
        let restoredStore = ProjectStore(defaults: defaults)

        XCTAssertEqual(store.projects.map(\.runnerID), ["shared-runner", "shared-runner-2"])
        XCTAssertEqual(restoredStore.projects, store.projects)
    }

    func testRunningRunnerIsManagedOnlyAfterItsProjectIsSaved() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let model = AppModel(
            projects: store,
            runners: RunnerManager(),
            launchAtLogin: LaunchAtLoginController()
        )
        let runner = RunningRunner(
            processIdentifier: Int32.max,
            runnerID: "existing-runner",
            path: "/tmp/example-project",
            command: "amp --no-tui --runner-id existing-runner"
        )

        XCTAssertFalse(model.isManaged(runner))

        store.add(directoryURL: URL(fileURLWithPath: "/tmp/example-project", isDirectory: true))

        XCTAssertTrue(model.isManaged(runner))
    }

    func testEnablingAutoStartAdoptsAnAvailableRunnerImmediately() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let model = AppModel(
            projects: store,
            runners: RunnerManager(),
            launchAtLogin: LaunchAtLoginController()
        )
        let runner = RunningRunner(
            processIdentifier: Int32.max,
            runnerID: "existing-runner",
            path: "/tmp/example-project",
            command: "amp --no-tui --runner-id existing-runner"
        )

        model.setAutoStarts(true, for: runner)

        XCTAssertTrue(model.isManaged(runner))
        XCTAssertTrue(model.autoStarts(runner))
        XCTAssertEqual(store.projects.first?.runnerID, "existing-runner")
    }

    func testAdoptingAvailableRunnerMigratesItsProcessIntoTheApp() async throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let externalProcess = Process()
        externalProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        externalProcess.arguments = ["30"]
        try externalProcess.run()
        defer {
            if externalProcess.isRunning {
                externalProcess.terminate()
            }
            externalProcess.waitUntilExit()
        }

        let store = ProjectStore(defaults: defaults)
        let runners = RunnerManager()
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        let runner = RunningRunner(
            processIdentifier: externalProcess.processIdentifier,
            runnerID: "existing-runner",
            path: directoryURL.path,
            command: "amp --no-tui --runner-id existing-runner"
        )

        model.setAutoStarts(true, for: runner)
        try FileManager.default.removeItem(at: directoryURL)

        for _ in 0..<50 {
            if case .failed = runners.state(for: try XCTUnwrap(store.projects.first)) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(externalProcess.isRunning)
        XCTAssertTrue(model.isManaged(runner))
        guard case .failed = runners.state(for: try XCTUnwrap(store.projects.first)) else {
            return XCTFail("The app should start its replacement after stopping the external runner")
        }
    }

    func testMigrationDoesNotKillAProcessThatIgnoresTermination() async throws {
        let externalProcess = Process()
        externalProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        externalProcess.arguments = [
            "-c",
            "trap '' TERM; exec /usr/bin/tail -f /dev/null",
        ]
        try externalProcess.run()
        defer {
            if externalProcess.isRunning {
                Darwin.kill(externalProcess.processIdentifier, SIGKILL)
            }
            externalProcess.waitUntilExit()
        }
        try await Task.sleep(for: .milliseconds(100))

        let project = RunnerProject(path: "/tmp/example-project")
        let runner = RunningRunner(
            processIdentifier: externalProcess.processIdentifier,
            runnerID: project.runnerID,
            path: project.path,
            command: "amp --no-tui --runner-id \(project.runnerID)"
        )
        let runners = RunnerManager()

        runners.migrate(runner, to: project)

        for _ in 0..<60 {
            if case .failed = runners.state(for: project) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(externalProcess.isRunning)
        guard case .failed = runners.state(for: project) else {
            return XCTFail("Migration should fail when the runner ignores SIGTERM")
        }
    }

    func testAddingProjectEnablesAutoStartAndAttemptsLaunch() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let runners = RunnerManager()
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        let directoryURL = URL(
            fileURLWithPath: "/tmp/missing-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let existingProject = store.add(directoryURL: directoryURL)
        store.setStartsAutomatically(false, for: existingProject.id)

        let project = model.addProject(directoryURL: directoryURL)

        XCTAssertTrue(store.projects.first?.startsAutomatically == true)
        guard case .failed = runners.state(for: project) else {
            return XCTFail("Adding a project should immediately attempt to start its runner")
        }
    }

    func testRunnerIDEditsAreNormalizedAndPersisted() throws {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectStore(defaults: defaults)
        let project = store.add(directoryURL: URL(fileURLWithPath: "/tmp/example-project"))

        let runnerID = store.setRunnerID("  My Custom_Runner!!  ", for: project.id)
        let restoredStore = ProjectStore(defaults: defaults)

        XCTAssertEqual(runnerID, "my-custom-runner")
        XCTAssertEqual(restoredStore.projects.first?.runnerID, "my-custom-runner")
    }
}
