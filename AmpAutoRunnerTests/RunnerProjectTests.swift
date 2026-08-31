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
        """

        let runners = RunnerProcessScanner.parseProcessList(
            processList,
            workingDirectories: [1746: "/tmp/beacon", 1747: "/tmp/dotfiles"]
        )

        XCTAssertEqual(runners.count, 2)
        XCTAssertEqual(runners[0].processIdentifier, 1746)
        XCTAssertEqual(runners[0].runnerID, "beacon")
        XCTAssertEqual(runners[0].path, "/tmp/beacon")
        XCTAssertEqual(runners[1].runnerID, "dotfiles")
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
}
