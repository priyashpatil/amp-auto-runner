import Combine
import XCTest
@testable import AmpAutoRunner

final class RunnerProjectTests: XCTestCase {
    func testLegacyAutoStartSettingMigratesToServedState() throws {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let data = Data("""
        {"id":"\(id.uuidString)","path":"/tmp/example","runnerID":"old-runner","startsAutomatically":false}
        """.utf8)

        let project = try JSONDecoder().decode(RunnerProject.self, from: data)

        XCTAssertEqual(project.id, id)
        XCTAssertEqual(project.path, "/tmp/example")
        XCTAssertFalse(project.isServed)
    }

    func testNewServedSettingTakesPrecedenceOverLegacyAutoStart() throws {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let data = Data("""
        {"id":"\(id.uuidString)","path":"/tmp/example","isServed":false,"startsAutomatically":true}
        """.utf8)

        let project = try JSONDecoder().decode(RunnerProject.self, from: data)

        XCTAssertFalse(project.isServed)
    }

    @MainActor
    func testRunnerUsesOneStableHostnameSafeID() {
        let manager = RunnerManager(runnerID: "test-mac-auto-runner")

        XCTAssertEqual(manager.runnerID, "test-mac-auto-runner")
        XCTAssertEqual(manager.runningCount, 0)
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

    func testRunnerDirectoryListParserPreservesSpacesAndExpandsHome() {
        let output = """
        Runner test-runner serves 2 directories:
          ~/code/project one
          /tmp/project two
        """

        XCTAssertEqual(
            RunnerManager.parseServedDirectoryPaths(
                output,
                homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
            ),
            ["/Users/example/code/project one", "/tmp/project two"]
        )
    }

    @MainActor
    func testReconciliationWaitsForPendingDirectoryAdd() async throws {
        let anchorPath = "/tmp/anchor-project"
        let addedPath = "/tmp/added-project"
        let addStarted = expectation(description: "Directory add started")
        let addCompleted = expectation(description: "Directory add completed")
        let initialReconciliationCompleted = expectation(
            description: "Initial reconciliation completed"
        )
        let overlappingReconciliationCompleted = expectation(
            description: "Overlapping reconciliation completed"
        )
        let allowAddToFinish = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var actualPaths: Set<String> = [anchorPath]
        var removedAddedDirectory = false
        var listCount = 0
        let manager = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                lock.lock()
                defer { lock.unlock() }
                if arguments.contains("list") {
                    listCount += 1
                    if listCount == 1 {
                        initialReconciliationCompleted.fulfill()
                    } else {
                        overlappingReconciliationCompleted.fulfill()
                    }
                    let paths = actualPaths.sorted().map { "  \($0)" }.joined(separator: "\n")
                    return .success("Runner test-runner serves \(actualPaths.count) directories:\n\(paths)")
                }
                if arguments.contains("add"), arguments.contains(addedPath) {
                    lock.unlock()
                    addStarted.fulfill()
                    allowAddToFinish.wait()
                    lock.lock()
                    actualPaths.insert(addedPath)
                    return .success("")
                }
                if arguments.contains("remove"), arguments.contains(addedPath) {
                    removedAddedDirectory = true
                    actualPaths.remove(addedPath)
                    return .success("")
                }
                return .failure("Unexpected command: \(arguments)")
            }
        )
        let firstRunner = RunningRunner(
            processIdentifier: 1234,
            runnerID: manager.runnerID,
            path: anchorPath,
            command: "amp --no-tui --runner-id test-runner"
        )
        manager.applyScanResult([firstRunner])
        manager.start(directories: [URL(fileURLWithPath: anchorPath, isDirectory: true)])
        await fulfillment(of: [initialReconciliationCompleted], timeout: 2)

        manager.addDirectory(URL(fileURLWithPath: addedPath, isDirectory: true)) { succeeded in
            XCTAssertTrue(succeeded)
            addCompleted.fulfill()
        }
        await fulfillment(of: [addStarted], timeout: 2)
        manager.applyScanResult([
            RunningRunner(
                processIdentifier: 5678,
                runnerID: manager.runnerID,
                path: anchorPath,
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])
        allowAddToFinish.signal()

        await fulfillment(of: [addCompleted, overlappingReconciliationCompleted], timeout: 2)
        let (finalPaths, didRemoveAddedDirectory) = lock.withLock {
            (actualPaths, removedAddedDirectory)
        }

        XCTAssertEqual(finalPaths, [anchorPath, addedPath])
        XCTAssertFalse(didRemoveAddedDirectory)
    }

    @MainActor
    func testFailedReconciliationRetriesForTheSameRunnerProcess() async throws {
        let desiredPath = "/tmp/desired-project"
        let firstAttempt = expectation(description: "First reconciliation attempted")
        let secondAttempt = expectation(description: "Reconciliation retried")
        let lock = NSLock()
        var listAttemptCount = 0
        let manager = RunnerManager(
            runnerID: "test-runner",
            ampExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            directoryCommandExecutor: RunnerDirectoryCommandExecutor { _, arguments in
                guard arguments.contains("list") else {
                    return .failure("Unexpected command: \(arguments)")
                }
                lock.lock()
                listAttemptCount += 1
                let attempt = listAttemptCount
                lock.unlock()
                if attempt == 1 {
                    firstAttempt.fulfill()
                    return .failure("Temporary failure")
                }
                secondAttempt.fulfill()
                return .success("Runner test-runner serves 1 directory:\n  \(desiredPath)")
            }
        )
        let runningRunner = RunningRunner(
            processIdentifier: 1234,
            runnerID: manager.runnerID,
            path: desiredPath,
            command: "amp --no-tui --runner-id test-runner"
        )
        manager.applyScanResult([runningRunner])
        manager.start(directories: [URL(fileURLWithPath: desiredPath, isDirectory: true)])

        await fulfillment(of: [firstAttempt], timeout: 2)
        for _ in 0..<20 where manager.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        manager.applyScanResult([runningRunner])

        await fulfillment(of: [secondAttempt], timeout: 2)
        XCTAssertEqual(listAttemptCount, 2)
    }

    @MainActor
    func testDiscoveredRunnerBecomesStoppedAfterItDisappears() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        let manager = RunnerManager(runnerID: "test-runner")
        manager.applyScanResult([
            RunningRunner(
                processIdentifier: process.processIdentifier,
                runnerID: manager.runnerID,
                path: "/tmp",
                command: "amp --no-tui --runner-id test-runner"
            ),
        ])

        manager.stop()
        process.waitUntilExit()
        manager.applyScanResult([])

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.isRunning)
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
