import Combine
import Darwin
import Foundation

struct RunningRunner: Equatable, Identifiable {
    let processIdentifier: Int32
    let runnerID: String
    let path: String?
    let command: String

    var id: Int32 {
        processIdentifier
    }

    var directoryURL: URL? {
        path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var projectName: String {
        guard let directoryURL else {
            return runnerID
        }

        let name = directoryURL.lastPathComponent
        return name.isEmpty ? runnerID : name
    }
}

enum RunnerState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

enum RunnerDirectoryCommandResult: Equatable {
    case success(String)
    case failure(String)
}

struct RunnerDirectoryCommandExecutor {
    let execute: (URL, [String]) -> RunnerDirectoryCommandResult

    static let live = RunnerDirectoryCommandExecutor { executableURL, arguments in
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                return .failure(error.isEmpty ? output : error)
            }
            return .success(output)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private struct RunnerTerminal {
    let master: FileHandle
    let slave: FileHandle
}

struct RunnerLogSnapshot: Equatable {
    let revision: UInt64
    let retainedOutput: String
    let appendedOutput: String

    static let empty = RunnerLogSnapshot(
        revision: 0,
        retainedOutput: "",
        appendedOutput: ""
    )
}

final class RunnerLogStore: ObservableObject {
    @Published private(set) var snapshot = RunnerLogSnapshot.empty

    private let maximumHistoryBytes: Int
    private let publishInterval: TimeInterval
    private let queue = DispatchQueue(label: "AmpAutoRunner.runner-logs", qos: .utility)
    private var pendingData = Data()
    private var incompleteUTF8Data = Data()
    private var retainedOutput = ""
    private var revision: UInt64 = 0
    private var scheduledFlush: DispatchWorkItem?

    init(
        maximumHistoryBytes: Int = 200_000,
        publishInterval: TimeInterval = 0.1
    ) {
        self.maximumHistoryBytes = maximumHistoryBytes
        self.publishInterval = publishInterval
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingData.append(data)
            guard self.scheduledFlush == nil else {
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.publishPendingOutput()
            }
            self.scheduledFlush = workItem
            self.queue.asyncAfter(
                deadline: .now() + self.publishInterval,
                execute: workItem
            )
        }
    }

    @MainActor
    func flushPendingOutput() {
        let nextSnapshot = queue.sync {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            return makeSnapshot()
        }

        if let nextSnapshot {
            snapshot = nextSnapshot
        }
    }

    private func publishPendingOutput() {
        scheduledFlush = nil
        guard let nextSnapshot = makeSnapshot() else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.snapshot = nextSnapshot
        }
    }

    private func makeSnapshot() -> RunnerLogSnapshot? {
        guard !pendingData.isEmpty else {
            return nil
        }

        let appendedOutput = decodePendingOutput()
        guard !appendedOutput.isEmpty else {
            return nil
        }
        retainedOutput.append(appendedOutput)
        trimHistoryIfNeeded()
        revision &+= 1

        return RunnerLogSnapshot(
            revision: revision,
            retainedOutput: retainedOutput,
            appendedOutput: appendedOutput
        )
    }

    private func decodePendingOutput() -> String {
        incompleteUTF8Data.append(pendingData)
        pendingData.removeAll(keepingCapacity: true)

        let maximumTrailingByteCount = min(3, incompleteUTF8Data.count)
        for trailingByteCount in 0...maximumTrailingByteCount {
            let prefixCount = incompleteUTF8Data.count - trailingByteCount
            let prefix = incompleteUTF8Data.prefix(prefixCount)
            guard let decoded = String(data: prefix, encoding: .utf8) else {
                continue
            }

            let trailingData = incompleteUTF8Data.suffix(trailingByteCount)
            incompleteUTF8Data = Data(trailingData)
            return decoded
        }

        let decoded = String(decoding: incompleteUTF8Data, as: UTF8.self)
        incompleteUTF8Data.removeAll(keepingCapacity: true)
        return decoded
    }

    private func trimHistoryIfNeeded() {
        let utf8 = retainedOutput.utf8
        guard utf8.count > maximumHistoryBytes else {
            return
        }

        let overflow = utf8.count - maximumHistoryBytes
        var byteIndex = utf8.index(utf8.startIndex, offsetBy: overflow)
        while byteIndex < utf8.endIndex, byteIndex.samePosition(in: retainedOutput) == nil {
            byteIndex = utf8.index(after: byteIndex)
        }

        guard var removalEnd = byteIndex.samePosition(in: retainedOutput) else {
            retainedOutput = ""
            return
        }

        let alreadyAtLineBoundary = retainedOutput[..<removalEnd].last == "\n"
        if
            !alreadyAtLineBoundary,
            let newline = retainedOutput[removalEnd...].firstIndex(of: "\n")
        {
            removalEnd = retainedOutput.index(after: newline)
        }
        retainedOutput.removeSubrange(..<removalEnd)
    }
}

private final class RunnerOutputArchive {
    private let lock = NSLock()
    private var capturedData: [RunnerProject.ID: Data] = [:]

    func reset(projectID: RunnerProject.ID) {
        lock.lock()
        capturedData[projectID] = Data()
        lock.unlock()
    }

    func append(_ data: Data, projectID: RunnerProject.ID) {
        lock.lock()
        guard var projectData = capturedData[projectID] else {
            lock.unlock()
            return
        }
        projectData.append(data)
        if projectData.count > 50_000 {
            projectData.removeFirst(projectData.count - 50_000)
        }
        capturedData[projectID] = projectData
        lock.unlock()
    }

    func take(projectID: RunnerProject.ID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedData.removeValue(forKey: projectID)
    }
}

enum RunnerEnvironment {
    static func loginShellURL(inheritedEnvironment: [String: String]) -> URL {
        var shellPaths: [String] = []
        if let inheritedShell = inheritedEnvironment["SHELL"] {
            shellPaths.append(inheritedShell)
        }
        if
            let passwordEntry = getpwuid(getuid()),
            let accountShell = passwordEntry.pointee.pw_shell
        {
            shellPaths.append(String(cString: accountShell))
        }
        shellPaths.append(contentsOf: ["/bin/zsh", "/bin/bash"])

        return shellPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/bin/sh")
    }

    static func executableSearchPath(
        inheritedPath: String?,
        homeDirectory: URL,
        ampExecutableURL: URL
    ) -> String {
        var paths = inheritedPath?
            .split(separator: ":")
            .map(String.init) ?? []
        let standardPaths = [
            ampExecutableURL.deletingLastPathComponent().path,
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
        ]

        for path in standardPaths where !paths.contains(path) {
            paths.append(path)
        }
        return paths.joined(separator: ":")
    }
}

enum RunnerProcessScanner {
    static func scan() -> [RunningRunner] {
        guard let processList = commandOutput(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="]
        ) else {
            return []
        }

        let candidates = parseProcessList(processList, workingDirectories: [:])
        guard !candidates.isEmpty else {
            return []
        }

        let processIdentifiers = candidates
            .map { String($0.processIdentifier) }
            .joined(separator: ",")
        let lsofOutput = commandOutput(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-d", "cwd", "-p", processIdentifiers, "-Fn"]
        ) ?? ""
        let workingDirectories = parseWorkingDirectories(lsofOutput)

        return parseProcessList(processList, workingDirectories: workingDirectories)
            .sorted {
                $0.runnerID.localizedStandardCompare($1.runnerID) == .orderedAscending
            }
    }

    static func parseProcessList(
        _ output: String,
        workingDirectories: [Int32: String]
    ) -> [RunningRunner] {
        output.split(separator: "\n").compactMap { line in
            let trimmedLine = line.drop(while: { $0.isWhitespace })
            guard
                let separatorIndex = trimmedLine.firstIndex(where: { $0.isWhitespace }),
                let processIdentifier = Int32(trimmedLine[..<separatorIndex])
            else {
                return nil
            }

            let command = trimmedLine[separatorIndex...]
                .trimmingCharacters(in: .whitespaces)
            let arguments = command.split(whereSeparator: { $0.isWhitespace })
            guard
                let executable = arguments.first,
                executable.split(separator: "/").last == "amp",
                arguments.contains("--no-tui")
            else {
                return nil
            }

            let path = workingDirectories[processIdentifier].map(normalizedPath)
            let runnerID = runnerID(in: arguments)
                ?? inferredRunnerID(processIdentifier: processIdentifier, path: path)

            return RunningRunner(
                processIdentifier: processIdentifier,
                runnerID: runnerID,
                path: path,
                command: command
            )
        }
    }

    static func parseWorkingDirectories(_ output: String) -> [Int32: String] {
        var workingDirectories: [Int32: String] = [:]
        var currentProcessIdentifier: Int32?

        for line in output.split(separator: "\n") {
            guard let field = line.first else {
                continue
            }

            switch field {
            case "p":
                currentProcessIdentifier = Int32(line.dropFirst())
            case "n":
                guard let currentProcessIdentifier else {
                    continue
                }
                workingDirectories[currentProcessIdentifier] = normalizedPath(String(line.dropFirst()))
            default:
                continue
            }
        }

        return workingDirectories
    }

    private static func runnerID(in arguments: [Substring]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--runner-id", arguments.indices.contains(index + 1) {
                return cleanArgument(arguments[index + 1])
            }

            if argument.hasPrefix("--runner-id=") {
                return cleanArgument(argument.dropFirst("--runner-id=".count))
            }
        }

        return nil
    }

    private static func inferredRunnerID(processIdentifier: Int32, path: String?) -> String {
        if
            let path,
            let runnerID = normalizedRunnerID(
                URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
            )
        {
            return runnerID
        }

        return "amp-runner-\(processIdentifier)"
    }

    private static func normalizedRunnerID(_ value: String) -> String? {
        let normalized = value.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122:
                return Character(String(scalar))
            default:
                return "-"
            }
        }
        let result = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return result.isEmpty ? nil : result
    }

    private static func cleanArgument(_ argument: Substring) -> String {
        String(argument).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func commandOutput(executableURL: URL, arguments: [String]) -> String? {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

@MainActor
final class RunnerManager: ObservableObject {
    @Published private(set) var state: RunnerState = .stopped
    @Published private(set) var runningRunners: [RunningRunner] = []
    @Published private(set) var hasCompletedInitialScan = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var servedDirectoryPaths: Set<String>?

    let logs = RunnerLogStore()
    let runnerID: String

    private var process: Process?
    private var terminal: RunnerTerminal?
    private let outputArchive = RunnerOutputArchive()
    private let outputID = UUID()
    private var isStopping = false
    private var scanTimer: Timer?
    private var scanInProgress = false
    private let scannerQueue = DispatchQueue(label: "AmpAutoRunner.runner-scanner", qos: .utility)
    private let directoryQueue = DispatchQueue(label: "AmpAutoRunner.runner-directories", qos: .utility)
    private let ampExecutableURLOverride: URL?
    private let directoryCommandExecutor: RunnerDirectoryCommandExecutor
    private let runnerRootDirectoryURL: URL
    private var refreshingDirectoriesProcessIdentifier: Int32?
    private var isAttachingInitialDirectories = false

    init(
        runnerID: String? = nil,
        ampExecutableURL: URL? = nil,
        directoryCommandExecutor: RunnerDirectoryCommandExecutor = .live,
        runnerRootDirectoryURL: URL? = nil
    ) {
        self.runnerID = runnerID ?? RunnerManager.defaultRunnerID
        ampExecutableURLOverride = ampExecutableURL
        self.directoryCommandExecutor = directoryCommandExecutor
        self.runnerRootDirectoryURL = runnerRootDirectoryURL
            ?? Self.defaultRunnerRootDirectoryURL
    }

    private static var defaultRunnerRootDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.priyashpatil.AmpAutoRunner"
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Runner Root", isDirectory: true)
    }

    static var defaultRunnerID: String {
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
            ?? "mac"
        let normalized = host.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122:
                return Character(String(scalar))
            default:
                return "-"
            }
        }
        let name = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
#if DEBUG
        let suffix = "-auto-runner-debug"
#else
        let suffix = "-auto-runner"
#endif
        let maximumNameLength = 63 - suffix.count
        let shortenedName = (name.isEmpty ? "mac" : name).prefix(maximumNameLength)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(shortenedName)\(suffix)"
    }

    var isRunning: Bool {
        process?.isRunning == true || runningRunners.contains { $0.runnerID == runnerID }
    }

    var runningCount: Int {
        isRunning ? 1 : 0
    }

    func startMonitoring() {
        guard scanTimer == nil else {
            return
        }

        refreshRunningRunners()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshRunningRunners()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    func stopMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func refreshRunningRunners() {
        guard !scanInProgress else {
            return
        }

        scanInProgress = true
        scannerQueue.async { [weak self] in
            let discoveredRunners = RunnerProcessScanner.scan()
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.scanInProgress = false
                self.applyScanResult(discoveredRunners)
            }
        }
    }

    func applyScanResult(_ discoveredRunners: [RunningRunner]) {
        let isInitialScan = !hasCompletedInitialScan
        if isInitialScan || runningRunners != discoveredRunners {
            runningRunners = discoveredRunners
        }
        if process?.isRunning != true {
            let matchingRunner = discoveredRunners.first { $0.runnerID == runnerID }
            if state == .stopping {
                if matchingRunner == nil {
                    state = .stopped
                }
            } else if matchingRunner != nil {
                state = .running
            } else if state == .running {
                state = .stopped
            }
        }

        if
            !isAttachingInitialDirectories,
            let matchingRunner = discoveredRunners.first(where: { $0.runnerID == runnerID })
        {
            if matchingRunner.processIdentifier != refreshingDirectoriesProcessIdentifier {
                refreshingDirectoriesProcessIdentifier = matchingRunner.processIdentifier
                refreshServedDirectories(processIdentifier: matchingRunner.processIdentifier)
            }
        } else {
            refreshingDirectoriesProcessIdentifier = nil
            if servedDirectoryPaths != nil {
                servedDirectoryPaths = nil
            }
        }

        if isInitialScan {
            hasCompletedInitialScan = true
        }
    }

    func start(directories: [URL]) {
        guard process == nil else {
            return
        }
        guard !directories.isEmpty else {
            if isRunning {
                stop()
            } else {
                state = .stopped
            }
            return
        }
        guard !isRunning else {
            let processIdentifier = runningRunners
                .first(where: { $0.runnerID == runnerID })?
                .processIdentifier
            if processIdentifier != refreshingDirectoriesProcessIdentifier {
                refreshingDirectoriesProcessIdentifier = processIdentifier
                refreshServedDirectories(processIdentifier: processIdentifier)
            }
            return
        }
        guard directories.allSatisfy({ isDirectory($0) }) else {
            fail("One or more served directories no longer exist.")
            return
        }

        guard let ampExecutableURL = ampExecutableURL() else {
            fail("Amp CLI was not found. Install Amp in ~/.local/bin or a standard Homebrew location.")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: runnerRootDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            fail("Could not prepare the shared runner: \(error.localizedDescription)")
            return
        }

        errorMessage = nil
        state = .starting
        outputArchive.reset(projectID: outputID)

        guard let terminal = makePseudoTerminal() else {
            _ = outputArchive.take(projectID: outputID)
            fail("Could not create a terminal for Amp.")
            return
        }

        var environment = ProcessInfo.processInfo.environment
        let loginShellURL = RunnerEnvironment.loginShellURL(inheritedEnvironment: environment)
        let process = Process()
        process.executableURL = loginShellURL
        let arguments = [
            "-l", "-i", "-c",
            "export TERM=xterm-256color COLORTERM=truecolor FORCE_COLOR=3; unset NO_COLOR; exec \"$@\"",
            loginShellURL.lastPathComponent,
            ampExecutableURL.path,
            "--no-tui",
            "--runner-id", runnerID,
            "--remote-control-terminal",
        ]
        process.arguments = arguments
        process.currentDirectoryURL = runnerRootDirectoryURL
        process.standardOutput = terminal.slave
        process.standardError = terminal.slave
        process.standardInput = FileHandle.nullDevice

        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["FORCE_COLOR"] = "3"
        environment["NO_COLOR"] = nil
        environment["PATH"] = RunnerEnvironment.executableSearchPath(
            inheritedPath: environment["PATH"],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            ampExecutableURL: ampExecutableURL
        )
        process.environment = environment

        let logs = logs
        let outputArchive = outputArchive
        let outputID = outputID
        terminal.master.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            outputArchive.append(data, projectID: outputID)
            logs.append(data)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                self?.processDidTerminate(terminatedProcess)
            }
        }

        self.process = process
        self.terminal = terminal

        do {
            isAttachingInitialDirectories = true
            try process.run()
            attachInitialDirectories(
                directories,
                executableURL: ampExecutableURL,
                process: process
            )
            refreshRunningRunners()
        } catch {
            isAttachingInitialDirectories = false
            terminal.master.readabilityHandler = nil
            terminal.master.closeFile()
            terminal.slave.closeFile()
            self.process = nil
            self.terminal = nil
            _ = outputArchive.take(projectID: outputID)
            fail(error.localizedDescription)
        }
    }

    func addDirectory(
        _ directory: URL,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        updateDirectory(directory, command: "add", completion: completion)
    }

    func removeDirectory(
        _ directory: URL,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        updateDirectory(directory, command: "remove", completion: completion)
    }

    func clearError() {
        errorMessage = nil
    }

    func stop() {
        if let process, process.isRunning {
            isStopping = true
            state = .stopping
            process.terminate()
            return
        }
        guard let runner = runningRunners.first(where: { $0.runnerID == runnerID }) else {
            state = .stopped
            return
        }
        if Darwin.kill(runner.processIdentifier, SIGTERM) == 0 {
            state = .stopping
        } else {
            fail("Could not stop the Amp runner.")
        }
    }

    func stopAll() {
        if let process, process.isRunning {
            isStopping = true
            process.terminate()
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else {
            return
        }

        isAttachingInitialDirectories = false
        terminal?.master.readabilityHandler = nil
        terminal?.master.closeFile()
        terminal?.slave.closeFile()
        terminal = nil
        process = nil
        let capturedOutput = outputArchive.take(projectID: outputID)

        if isStopping || terminatedProcess.terminationStatus == 0 {
            state = .stopped
        } else {
            let output = capturedOutput.map {
                String(decoding: $0, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let detail = output.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Amp exited with status \(terminatedProcess.terminationStatus)."
            fail(detail)
        }

        isStopping = false
        refreshRunningRunners()
    }

    private func attachInitialDirectories(
        _ directories: [URL],
        executableURL: URL,
        process launchedProcess: Process
    ) {
        let runnerID = runnerID
        let executor = directoryCommandExecutor
        directoryQueue.async { [weak self] in
            var failure: String?
            for directory in directories {
                var result: RunnerDirectoryCommandResult = .failure("")
                for _ in 0..<20 {
                    result = executor.execute(
                        executableURL,
                        ["runner", "dirs", "add", directory.path, "--runner-id", runnerID]
                    )
                    guard
                        case let .failure(detail) = result,
                        detail.contains("No running runner is listening")
                    else {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if case let .failure(detail) = result {
                    failure = detail.isEmpty ? "Could not attach served directories." : detail
                    break
                }
            }

            DispatchQueue.main.async {
                guard let self, self.process === launchedProcess else {
                    return
                }
                self.isAttachingInitialDirectories = false
                self.state = .running
                if let failure {
                    self.reportCommandFailure(failure)
                }
                self.refreshRunningRunners()
            }
        }
    }

    private func updateDirectory(
        _ directory: URL,
        command: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let ampExecutableURL = ampExecutableURL() else {
            fail("Amp CLI was not found.")
            completion(false)
            return
        }
        errorMessage = nil
        let runnerID = runnerID
        let executor = directoryCommandExecutor
        directoryQueue.async { [weak self] in
            let result = executor.execute(
                ampExecutableURL,
                [
                    "runner", "dirs", command, directory.path,
                    "--runner-id", runnerID,
                ]
            )
            DispatchQueue.main.sync {
                switch result {
                case .success:
                    completion(true)
                case let .failure(detail):
                    self?.reportCommandFailure(
                        detail.isEmpty ? "Could not update served directories." : detail
                    )
                    completion(false)
                }
            }
        }
    }

    private func refreshServedDirectories(processIdentifier: Int32?) {
        guard let ampExecutableURL = ampExecutableURL() else {
            reportCommandFailure("Amp CLI was not found.")
            refreshingDirectoriesProcessIdentifier = nil
            return
        }

        errorMessage = nil
        let runnerID = runnerID
        let executor = directoryCommandExecutor
        let excludedDirectoryPaths = [Self.normalizedPath(runnerRootDirectoryURL)]
        directoryQueue.async { [weak self] in
            guard let self else {
                return
            }
            var listResult = executor.execute(
                ampExecutableURL,
                ["runner", "dirs", "list", "--runner-id", runnerID]
            )
            for _ in 0..<19 {
                guard
                    case let .failure(detail) = listResult,
                    detail.contains("No running runner is listening")
                else {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
                listResult = executor.execute(
                    ampExecutableURL,
                    ["runner", "dirs", "list", "--runner-id", runnerID]
                )
            }

            guard case let .success(output) = listResult else {
                let detail: String
                if case let .failure(message) = listResult {
                    detail = message
                } else {
                    detail = "Could not inspect served directories."
                }
                DispatchQueue.main.async {
                    self.refreshingDirectoriesProcessIdentifier = nil
                    self.reportCommandFailure(detail)
                }
                return
            }

            let actualDirectoryPaths = Self.parseServedDirectoryPaths(
                output,
                excluding: Set(excludedDirectoryPaths)
            )
            DispatchQueue.main.async {
                guard self.refreshingDirectoriesProcessIdentifier == processIdentifier else {
                    return
                }
                self.refreshingDirectoriesProcessIdentifier = nil
                self.servedDirectoryPaths = actualDirectoryPaths
            }
        }
    }

    nonisolated static func parseServedDirectoryPaths(
        _ output: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        excluding excludedDirectoryPaths: Set<String> = []
    ) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            guard line.first?.isWhitespace == true else {
                return nil
            }
            var path = pathWithoutMetadata(
                line.trimmingCharacters(in: .whitespaces)
            )
            if path == "~" {
                path = homeDirectory.path
            } else if path.hasPrefix("~/") {
                path = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
            }
            guard path.hasPrefix("/") else {
                return nil
            }
            let normalizedPath = normalizedPath(URL(fileURLWithPath: path, isDirectory: true))
            return excludedDirectoryPaths.contains(normalizedPath) ? nil : normalizedPath
        })
    }

    nonisolated static func pathWithoutMetadata(_ value: String) -> String {
        guard
            value.hasSuffix(")"),
            let metadataStart = value.range(of: " (", options: .backwards)
        else {
            return value
        }

        let metadata = value[metadataStart.upperBound..<value.index(before: value.endIndex)]
        guard metadata.hasPrefix("git@") || metadata.contains("://") else {
            return value
        }
        return String(value[..<metadataStart.lowerBound])
    }

    private func fail(_ message: String) {
        state = .failed(message)
        errorMessage = message
    }

    private func reportCommandFailure(_ message: String) {
        let detail = message.isEmpty ? "Could not update served directories." : message
        errorMessage = detail
        logs.append(Data("[Amp Auto Runner] \(detail)\n".utf8))
    }

    nonisolated private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func makePseudoTerminal() -> RunnerTerminal? {
        var masterDescriptor: Int32 = 0
        var slaveDescriptor: Int32 = 0
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0 else {
            return nil
        }

        return RunnerTerminal(
            master: FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true),
            slave: FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
        )
    }

    private func ampExecutableURL() -> URL? {
        if let ampExecutableURLOverride {
            return ampExecutableURLOverride
        }

        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("amp") }
            ?? []

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let knownLocations = [
            homeDirectory.appendingPathComponent(".local/bin/amp"),
            homeDirectory.appendingPathComponent("bin/amp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/amp"),
            URL(fileURLWithPath: "/usr/local/bin/amp"),
            URL(fileURLWithPath: "/usr/bin/amp"),
        ]

        return (environmentPaths + knownLocations).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
