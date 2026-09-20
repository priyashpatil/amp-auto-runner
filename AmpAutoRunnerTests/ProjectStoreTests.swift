import AppKit
import SwiftUI
import XCTest
@testable import AmpAutoRunner

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testRunnerLogsAreShownInitiallyAndCanBeHidden() {
        let model = AppModel()

        XCTAssertTrue(model.showsRunnerLogs)

        model.setRunnerLogsVisible(false)
        XCTAssertFalse(model.showsRunnerLogs)
    }

    func testDirectoriesPersistAndDuplicatePathsAreIgnored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let directoryURL = URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)

        let firstProject = store.add(directoryURL: directoryURL)
        let duplicateProject = store.add(directoryURL: directoryURL)
        let restoredStore = ProjectStore(defaults: defaults)

        XCTAssertEqual(firstProject.id, duplicateProject.id)
        XCTAssertEqual(restoredStore.projects, [firstProject])
    }

    func testServedStatePersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let project = store.add(
            directoryURL: URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)
        )

        store.setIsServed(false, for: project.id)

        XCTAssertFalse(try XCTUnwrap(ProjectStore(defaults: defaults).projects.first).isServed)
    }

    func testAddingMissingDirectoryAttemptsToStartSharedRunner() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let runners = RunnerManager(runnerID: "test-runner")
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        let directoryURL = URL(
            fileURLWithPath: "/tmp/missing-project-\(UUID().uuidString)",
            isDirectory: true
        )

        let project = model.addProject(directoryURL: directoryURL)

        XCTAssertTrue(project.isServed)
        guard case .failed = runners.state else {
            return XCTFail("Adding the first directory should attempt to start the shared runner")
        }
    }

    func testInitialScanStartsSavedServedDirectories() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        store.add(
            directoryURL: URL(
                fileURLWithPath: "/tmp/missing-project-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        let runners = RunnerManager(runnerID: "test-runner")
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        runners.applyScanResult([])

        guard case .failed = runners.state else {
            return XCTFail("The initial scan should start saved served directories")
        }
        withExtendedLifetime(model) {}
    }

    func testInitialScanAdoptsMatchingRunnerWithoutLaunchingAnotherProcess() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let directory = URL(fileURLWithPath: "/tmp/example project", isDirectory: true)
        store.add(directoryURL: directory)
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                if arguments.contains("list") {
                    return .success("Runner test-runner serves 1 directory:\n  \(directory.path)")
                }
                return .failure("Unexpected command")
            }
        )
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: directory.path,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])

        XCTAssertEqual(runners.state, .running)
        XCTAssertTrue(runners.isRunning)
        withExtendedLifetime(model) {}
    }

    func testInitialScanImportsCLIProjectIntoEmptyStoreWithoutStoppingRunner() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let directory = URL(fileURLWithPath: "/tmp/cli-project", isDirectory: true)
        let directoryListed = expectation(description: "CLI directory listed")
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                guard arguments.contains("list") else {
                    return .failure("Unexpected command: \(arguments)")
                }
                directoryListed.fulfill()
                return .success("Runner test-runner serves 1 directory:\n  \(directory.path)")
            }
        )
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 2_000_000_000,
                runnerID: runners.runnerID,
                path: directory.path,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])

        await fulfillment(of: [directoryListed], timeout: 2)
        for _ in 0..<20 where store.projects.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.projects.map(\.path), [directory.path])
        XCTAssertTrue(try XCTUnwrap(store.projects.first).isServed)
        XCTAssertEqual(runners.state, .running)
        withExtendedLifetime(model) {}
    }

    func testFailedLiveRemovalKeepsProjectServedAndReportsTheError() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let project = store.add(
            directoryURL: URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)
        )
        let removalAttempted = expectation(description: "Removal attempted")
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                if arguments.contains("list") {
                    return .success("Runner test-runner serves 1 directory:\n  \(project.path)")
                }
                if arguments.contains("remove") {
                    removalAttempted.fulfill()
                    return .failure("Permission denied")
                }
                return .failure("Unexpected command")
            }
        )
        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: project.path,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        model.setIsServed(false, for: project)
        await fulfillment(of: [removalAttempted], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(try XCTUnwrap(store.projects.first).isServed)
        XCTAssertEqual(runners.errorMessage, "Permission denied")
    }

    func testProjectCannotBeRemovedWhileItsDirectoryIsBeingAdded() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let addStarted = expectation(description: "Directory add started")
        let allowAddToFinish = DispatchSemaphore(value: 0)
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                guard arguments.contains("add") else {
                    return .failure("Unexpected command: \(arguments)")
                }
                addStarted.fulfill()
                allowAddToFinish.wait()
                return .success("")
            }
        )
        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: "/tmp",
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        let project = model.addProject(
            directoryURL: URL(fileURLWithPath: "/tmp/new-project", isDirectory: true)
        )

        await fulfillment(of: [addStarted], timeout: 2)
        model.remove(project)

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(model.pendingProjectIDs.contains(project.id))

        allowAddToFinish.signal()
        for _ in 0..<20 where model.pendingProjectIDs.contains(project.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(try XCTUnwrap(store.projects.first).isServed)
        XCTAssertFalse(model.pendingProjectIDs.contains(project.id))
    }

    func testDuplicateProjectAddDoesNotBypassPendingOperation() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let addStarted = expectation(description: "Directory add started once")
        addStarted.assertForOverFulfill = true
        let allowAddToFinish = DispatchSemaphore(value: 0)
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                guard arguments.contains("add") else {
                    return .failure("Unexpected command: \(arguments)")
                }
                addStarted.fulfill()
                allowAddToFinish.wait()
                return .failure("Add failed")
            }
        )
        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: "/tmp",
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        let directoryURL = URL(fileURLWithPath: "/tmp/new-project", isDirectory: true)
        let project = model.addProject(directoryURL: directoryURL)

        await fulfillment(of: [addStarted], timeout: 2)
        let duplicate = model.addProject(directoryURL: directoryURL)
        model.remove(project)

        XCTAssertEqual(duplicate.id, project.id)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(model.pendingProjectIDs.contains(project.id))

        allowAddToFinish.signal()
        for _ in 0..<20 where model.pendingProjectIDs.contains(project.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertFalse(try XCTUnwrap(store.projects.first).isServed)
        XCTAssertFalse(model.pendingProjectIDs.contains(project.id))
        XCTAssertEqual(runners.errorMessage, "Add failed")
    }

    func testRunnerDirectoryScansImportCLIChanges() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let desiredDirectory = URL(fileURLWithPath: "/tmp/desired project", isDirectory: true)
        let importedDirectory = URL(fileURLWithPath: "/tmp/imported project", isDirectory: true)
        let laterDirectory = URL(fileURLWithPath: "/tmp/later project", isDirectory: true)
        store.add(directoryURL: desiredDirectory)
        let firstList = expectation(description: "Initial CLI directories listed")
        let secondList = expectation(description: "Updated CLI directories listed")
        let lock = NSLock()
        var actualPaths = [desiredDirectory.path, importedDirectory.path]
        var listCount = 0
        let runners = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                if arguments.contains("list") {
                    return lock.withLock {
                        listCount += 1
                        if listCount == 1 {
                            firstList.fulfill()
                        } else {
                            secondList.fulfill()
                        }
                        let paths = actualPaths.map { "  \($0)" }.joined(separator: "\n")
                        return .success(
                            "Runner test-runner serves \(actualPaths.count) directories:\n\(paths)"
                        )
                    }
                }
                return .failure("Unexpected command: \(arguments)")
            }
        )
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: desiredDirectory.path,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])

        await fulfillment(of: [firstList], timeout: 2)
        for _ in 0..<20 where !store.projects.contains(where: { $0.path == importedDirectory.path }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(store.projects.contains {
            $0.path == importedDirectory.path && $0.isServed
        })

        lock.withLock {
            actualPaths = [importedDirectory.path, laterDirectory.path]
        }
        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: importedDirectory.path,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])

        await fulfillment(of: [secondList], timeout: 2)
        for _ in 0..<20 where !store.projects.contains(where: { $0.path == laterDirectory.path }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(try XCTUnwrap(store.projects.first { $0.path == desiredDirectory.path }).isServed)
        XCTAssertTrue(store.projects.contains {
            $0.path == laterDirectory.path && $0.isServed
        })
        withExtendedLifetime(model) {}
    }

    func testStoredGitMetadataPathMigratesBeforeRunnerScan() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let directory = URL(fileURLWithPath: "/tmp/rift", isDirectory: true)
        let malformedPath = "/tmp/rift (git@github.com:example/rift.git)"
        store.add(directoryURL: directory, isServed: false)
        store.add(
            directoryURL: URL(fileURLWithPath: malformedPath, isDirectory: true),
            isServed: true
        )
        let runners = RunnerManager(runnerID: "test-runner")
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )

        XCTAssertEqual(store.projects.map(\.path), [directory.path])
        XCTAssertTrue(try XCTUnwrap(store.projects.first).isServed)
        withExtendedLifetime(model) {}
    }

    func testDashboardRendersSharedRunnerDirectoryLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        store.add(
            directoryURL: URL(
                fileURLWithPath: "/Users/example/code/amp-auto-runner",
                isDirectory: true
            )
        )
        let runners = RunnerManager(runnerID: "example-mac-auto-runner")
        runners.applyScanResult([
            RunningRunner(
                processIdentifier: 1234,
                runnerID: runners.runnerID,
                path: "/Users/example/code",
                command: "amp --no-tui --runner-id example-mac-auto-runner"
            ),
        ])
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        try renderDashboard(model, filename: "shared-runner-dashboard.png")
    }

    func testDashboardRendersRunnerErrorNotice() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProjectStore(defaults: defaults)
        let directoryURL = URL(
            fileURLWithPath: "/tmp/missing-project-\(UUID().uuidString)",
            isDirectory: true
        )
        store.add(directoryURL: directoryURL)
        let runners = RunnerManager(runnerID: "example-mac-auto-runner")
        runners.start(directories: [directoryURL])
        let model = AppModel(
            projects: store,
            runners: runners,
            launchAtLogin: LaunchAtLoginController()
        )
        try renderDashboard(model, filename: "shared-runner-dashboard-error.png")
    }

    private func renderDashboard(_ model: AppModel, filename: String) throws {
        let dashboard = RunnerDashboardView(model: model).frame(width: 900, height: 620)
        let hostingView = NSHostingView(rootView: dashboard)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let screenshotURL = repositoryURL
            .appendingPathComponent("build/verification", isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: screenshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: screenshotURL)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ProjectStoreTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
