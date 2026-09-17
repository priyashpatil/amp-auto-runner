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
            .appendingPathComponent("shared-runner-dashboard.png")
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
