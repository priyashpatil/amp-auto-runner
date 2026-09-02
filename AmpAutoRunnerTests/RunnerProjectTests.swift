import Combine
import XCTest
@testable import AmpAutoRunner

final class RunnerProjectTests: XCTestCase {
    func testRunnerIDIsStableAndHostnameSafe() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let projectURL = URL(fileURLWithPath: "/tmp/Café Project!!", isDirectory: true)

        let runnerID = RunnerProject.makeRunnerID(for: projectURL, id: id)

        XCTAssertEqual(runnerID, "cafe-project-012345")
        XCTAssertLessThanOrEqual(runnerID.count, 63)
        XCTAssertNotNil(runnerID.range(of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", options: .regularExpression))
    }

    func testLongRunnerIDDoesNotExceedHostnameLabelLimit() {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let name = String(repeating: "long-project-name-", count: 10)
        let projectURL = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)

        let runnerID = RunnerProject.makeRunnerID(for: projectURL, id: id)

        XCTAssertEqual(runnerID.count, 63)
        XCTAssertEqual(runnerID.suffix(7), "-abcdef")
        XCTAssertFalse(runnerID.hasPrefix("-"))
        XCTAssertFalse(runnerID.hasSuffix("-"))
    }

    func testEditableRunnerIDIsNormalizedAndHostnameSafe() {
        let runnerID = RunnerProject.normalizedRunnerID("  Café_App Runner!!  ")

        XCTAssertEqual(runnerID, "cafe-app-runner")
    }

    func testProcessScannerFindsHeadlessAmpRunnersAndIgnoresOtherCommands() {
        let processList = """
          1746 /Users/example/.local/bin/amp --no-tui --remote-control-terminal --runner-id beacon
          1747 amp --runner-id=dotfiles --no-tui --remote-control-terminal
          2000 /bin/zsh -c amp --no-tui --runner-id not-a-process
          2001 /Users/example/.local/bin/amp --no-tui
          2002 amp --no-tui
        """

        let runners = RunnerProcessScanner.parseProcessList(
            processList,
            workingDirectories: [
                1746: "/tmp/beacon",
                1747: "/tmp/dotfiles",
                2001: "/tmp/Example Project",
            ]
        )

        XCTAssertEqual(runners.count, 4)
        XCTAssertEqual(runners[0].processIdentifier, 1746)
        XCTAssertEqual(runners[0].runnerID, "beacon")
        XCTAssertEqual(runners[0].path, "/tmp/beacon")
        XCTAssertEqual(runners[1].runnerID, "dotfiles")
        XCTAssertEqual(runners[2].runnerID, "example-project")
        XCTAssertEqual(runners[2].path, "/tmp/Example Project")
        XCTAssertEqual(runners[3].runnerID, "amp-runner-2002")
    }

    func testProcessScannerParsesWorkingDirectoriesFromLsofFields() {
        let output = """
        p1746
        fcwd
        n/tmp/beacon
        p1747
        fcwd
        n/tmp/dotfiles
        """

        XCTAssertEqual(
            RunnerProcessScanner.parseWorkingDirectories(output),
            [1746: "/tmp/beacon", 1747: "/tmp/dotfiles"]
        )
    }

    func testRunnerEnvironmentAddsExecutableLocationsMissingFromGUIPath() {
        let path = RunnerEnvironment.executableSearchPath(
            inheritedPath: "/usr/bin:/bin:/usr/bin",
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            ampExecutableURL: URL(fileURLWithPath: "/Users/example/.local/bin/amp")
        )
        let components = path.split(separator: ":").map(String.init)

        XCTAssertEqual(Array(components.prefix(3)), ["/usr/bin", "/bin", "/usr/bin"])
        XCTAssertEqual(components.filter { $0 == "/Users/example/.local/bin" }.count, 1)
        XCTAssertTrue(components.contains("/opt/homebrew/bin"))
        XCTAssertTrue(components.contains("/usr/local/bin"))
    }

    func testRunnerEnvironmentUsesConfiguredLoginShell() {
        let shell = RunnerEnvironment.loginShellURL(
            inheritedEnvironment: ["SHELL": "/bin/bash"]
        )

        XCTAssertEqual(shell.path, "/bin/bash")
    }

    func testRunnerMatchingPrefersKnownPathOverCollidingRunnerID() {
        let firstProject = RunnerProject(path: "/tmp/first", runnerID: "shared-runner")
        let secondProject = RunnerProject(path: "/tmp/second", runnerID: "second-runner")
        let runner = RunningRunner(
            processIdentifier: 1746,
            runnerID: "shared-runner",
            path: "/tmp/second",
            command: "amp --no-tui --runner-id shared-runner"
        )
        let projects = [firstProject, secondProject]

        XCTAssertEqual(
            RunnerMatcher.project(for: runner, among: projects, and: [runner]),
            secondProject
        )
        XCTAssertEqual(
            RunnerMatcher.runner(for: firstProject, among: projects, and: [runner]),
            .conflict
        )
    }

    func testRunnerIDOnlyMatchingRequiresOneRunnerAndOneProject() {
        let project = RunnerProject(path: "/tmp/example", runnerID: "shared-runner")
        let firstRunner = RunningRunner(
            processIdentifier: 1746,
            runnerID: "shared-runner",
            path: nil,
            command: "amp --no-tui --runner-id shared-runner"
        )
        let secondRunner = RunningRunner(
            processIdentifier: 1747,
            runnerID: "shared-runner",
            path: nil,
            command: "amp --no-tui --runner-id shared-runner"
        )

        XCTAssertEqual(
            RunnerMatcher.runner(for: project, among: [project], and: [firstRunner]),
            .matched(firstRunner)
        )
        XCTAssertEqual(
            RunnerMatcher.project(for: firstRunner, among: [project], and: [firstRunner]),
            project
        )
        XCTAssertEqual(
            RunnerMatcher.runner(
                for: project,
                among: [project],
                and: [firstRunner, secondRunner]
            ),
            .conflict
        )
        XCTAssertNil(
            RunnerMatcher.project(
                for: firstRunner,
                among: [project],
                and: [firstRunner, secondRunner]
            )
        )
    }

    func testTerminalFormatterConsumesANSIColorSequences() {
        let formatted = TerminalTextFormatter.attributedString(
            for: "plain \u{001B}[31mred\u{001B}[0m text"
        )

        XCTAssertEqual(String(formatted.characters), "plain red text")
        XCTAssertGreaterThan(formatted.runs.count, 1)
    }

    func testTerminalFormatterSupportsIndexedAndTrueColorSequences() {
        let formatted = TerminalTextFormatter.attributedString(
            for: "plain \u{001B}[38;5;201mindexed\u{001B}[0m "
                + "\u{001B}[38;2;12;180;240mtrue color\u{001B}[0m"
        )

        XCTAssertEqual(String(formatted.characters), "plain indexed true color")
        XCTAssertGreaterThanOrEqual(formatted.runs.count, 4)
    }

    func testTerminalFormatterConsumesANSILinkSequences() {
        let formatted = TerminalTextFormatter.attributedString(
            for: "open \u{001B}]8;;https://example.com\u{0007}T-example\u{001B}]8;;\u{0007} now"
        )

        XCTAssertEqual(String(formatted.characters), "open T-example now")
    }

    func testTerminalFormatterCarriesIncompleteANSISequencesAcrossAppends() {
        var parser = TerminalTextFormatter.Parser()

        let first = parser.nsAttributedString(for: "plain \u{001B}[3")
        let second = parser.nsAttributedString(for: "1mred\u{001B}[0m text")

        XCTAssertEqual(first.string, "plain ")
        XCTAssertEqual(second.string, "red text")
        XCTAssertGreaterThan(second.length, 0)
    }

    func testTerminalFormatterCarriesSplitLineEndingsAcrossAppends() {
        var parser = TerminalTextFormatter.Parser()

        let first = parser.nsAttributedString(for: "first\r")
        let second = parser.nsAttributedString(for: "\nsecond")

        XCTAssertEqual(first.string, "first")
        XCTAssertEqual(second.string, "\nsecond")
    }

    @MainActor
    func testTerminalTextCoordinatorIgnoresUnchangedSnapshotsAndAppendsNewOutput() {
        let textView = NSTextView()
        let coordinator = TerminalTextView.Coordinator()
        coordinator.attach(textView)

        coordinator.apply(
            RunnerLogSnapshot(
                revision: 1,
                retainedOutput: "plain \u{001B}[3",
                appendedOutput: "plain \u{001B}[3"
            ),
            fontSize: 12
        )
        XCTAssertEqual(textView.string, "plain ")

        coordinator.apply(
            RunnerLogSnapshot(
                revision: 1,
                retainedOutput: "this must not replace the rendered output",
                appendedOutput: "ignored"
            ),
            fontSize: 12
        )
        XCTAssertEqual(textView.string, "plain ")

        coordinator.apply(
            RunnerLogSnapshot(
                revision: 2,
                retainedOutput: "plain \u{001B}[31mred\u{001B}[0m text",
                appendedOutput: "1mred\u{001B}[0m text"
            ),
            fontSize: 12
        )
        XCTAssertEqual(textView.string, "plain red text")
    }

    @MainActor
    func testRunnerLogStoreCoalescesAndBoundsPendingOutput() {
        let logs = RunnerLogStore(
            maximumHistoryBytes: 12,
            publishInterval: 60
        )

        logs.append(Data("first\n".utf8))
        logs.append(Data("second\n".utf8))

        XCTAssertEqual(logs.snapshot, .empty)

        logs.flushPendingOutput()

        XCTAssertEqual(logs.snapshot.revision, 1)
        XCTAssertEqual(logs.snapshot.appendedOutput, "first\nsecond\n")
        XCTAssertEqual(logs.snapshot.retainedOutput, "second\n")
        XCTAssertLessThanOrEqual(logs.snapshot.retainedOutput.utf8.count, 12)
    }

    @MainActor
    func testRunnerLogStorePreservesUTF8AcrossFlushBoundaries() {
        let logs = RunnerLogStore(publishInterval: 60)
        let bytes = Array("A🙂B".utf8)

        logs.append(Data(bytes.prefix(3)))
        logs.flushPendingOutput()
        XCTAssertEqual(logs.snapshot.retainedOutput, "A")

        logs.append(Data(bytes.dropFirst(3)))
        logs.flushPendingOutput()

        XCTAssertEqual(logs.snapshot.retainedOutput, "A🙂B")
        XCTAssertEqual(logs.snapshot.appendedOutput, "🙂B")
    }

    @MainActor
    func testUnchangedRunnerScansDoNotPublishAgain() {
        let manager = RunnerManager()
        var runnerPublications = 0
        var objectChanges = 0
        let runnersCancellable = manager.$runningRunners
            .dropFirst()
            .sink { _ in runnerPublications += 1 }
        let objectCancellable = manager.objectWillChange
            .sink { objectChanges += 1 }

        manager.applyScanResult([])
        let changesAfterInitialScan = objectChanges
        manager.applyScanResult([])

        XCTAssertEqual(runnerPublications, 1)
        XCTAssertEqual(objectChanges, changesAfterInitialScan)

        let runner = RunningRunner(
            processIdentifier: 1746,
            runnerID: "example",
            path: "/tmp/example",
            command: "amp --no-tui --runner-id example"
        )
        manager.applyScanResult([runner])
        manager.applyScanResult([runner])

        XCTAssertEqual(runnerPublications, 2)
        withExtendedLifetime((runnersCancellable, objectCancellable)) {}
    }
}
