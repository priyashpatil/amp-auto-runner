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

enum RunnerMatch: Equatable {
    case none
    case matched(RunningRunner)
    case conflict
}

enum RunnerMatcher {
    static func runner(
        for project: RunnerProject,
        among projects: [RunnerProject],
        and runners: [RunningRunner]
    ) -> RunnerMatch {
        let pathMatches = runners.filter { $0.path == project.path }
        if pathMatches.count == 1, let runner = pathMatches.first {
            return .matched(runner)
        }
        if pathMatches.count > 1 {
            let runnerIDMatches = pathMatches.filter { $0.runnerID == project.runnerID }
            if runnerIDMatches.count == 1, let runner = runnerIDMatches.first {
                return .matched(runner)
            }
            return .conflict
        }

        guard projects.filter({ $0.runnerID == project.runnerID }).count == 1 else {
            return .conflict
        }

        let runnerIDMatches = runners.filter { $0.runnerID == project.runnerID }
        guard !runnerIDMatches.isEmpty else {
            return .none
        }
        guard
            runnerIDMatches.count == 1,
            runnerIDMatches.first?.path == nil,
            let runner = runnerIDMatches.first
        else {
            return .conflict
        }
        return .matched(runner)
    }

    static func project(
        for runner: RunningRunner,
        among projects: [RunnerProject],
        and runners: [RunningRunner]
    ) -> RunnerProject? {
        if let path = runner.path {
            let pathMatches = projects.filter { $0.path == path }
            if pathMatches.count == 1 {
                return pathMatches.first
            }
            if pathMatches.count > 1 {
                let runnerIDMatches = pathMatches.filter { $0.runnerID == runner.runnerID }
                return runnerIDMatches.count == 1 ? runnerIDMatches.first : nil
            }
            return nil
        }

        let projectMatches = projects.filter { $0.runnerID == runner.runnerID }
        let runnerMatches = runners.filter {
            $0.path == nil && $0.runnerID == runner.runnerID
        }
        guard
            projectMatches.count == 1,
            runnerMatches.count == 1,
            runnerMatches.first?.processIdentifier == runner.processIdentifier
        else {
            return nil
        }
        return projectMatches.first
    }
}

private struct RunnerTerminal {
    let master: FileHandle
    let slave: FileHandle
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
                arguments.contains("--no-tui"),
                let runnerID = runnerID(in: arguments)
            else {
                return nil
            }

            return RunningRunner(
                processIdentifier: processIdentifier,
                runnerID: runnerID,
                path: workingDirectories[processIdentifier].map(normalizedPath),
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
    @Published private(set) var states: [RunnerProject.ID: RunnerState] = [:]
    @Published private(set) var runningRunners: [RunningRunner] = []
    @Published private(set) var hasCompletedInitialScan = false
    @Published private(set) var capturedTerminalOutput = ""

    private var processes: [RunnerProject.ID: Process] = [:]
    private var terminals: [RunnerProject.ID: RunnerTerminal] = [:]
    private var capturedData: [RunnerProject.ID: Data] = [:]
    private var capturedTerminalData = Data()
    private var projectIDsByProcessIdentifier: [Int32: RunnerProject.ID] = [:]
    private var migrationTasks: [RunnerProject.ID: Task<Void, Never>] = [:]
    private var migratingProcessIdentifiers: [RunnerProject.ID: Int32] = [:]
    private var stoppingProjects: Set<RunnerProject.ID> = []
    private var lastStartAttempts: [RunnerProject.ID: Date] = [:]
    private var scanTimer: Timer?
    private var scanInProgress = false
    private let scannerQueue = DispatchQueue(label: "AmpAutoRunner.runner-scanner", qos: .utility)

    var runningCount: Int {
        var processIdentifiers = Set(runningRunners.map(\.processIdentifier))
        for process in processes.values where process.isRunning {
            processIdentifiers.insert(process.processIdentifier)
        }
        return processIdentifiers.count
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
                self.hasCompletedInitialScan = true
                self.runningRunners = discoveredRunners
            }
        }
    }

    func state(for project: RunnerProject) -> RunnerState {
        if let state = states[project.id], state == .starting || state == .stopping {
            return state
        }

        if runningRunner(for: project) != nil || processes[project.id]?.isRunning == true {
            return .running
        }

        return states[project.id] ?? .stopped
    }

    func runningRunner(for project: RunnerProject) -> RunningRunner? {
        guard case let .matched(runner) = RunnerMatcher.runner(
            for: project,
            among: [project],
            and: runningRunners
        ) else {
            return nil
        }
        return runner
    }

    func isOwned(_ runner: RunningRunner) -> Bool {
        projectIDsByProcessIdentifier[runner.processIdentifier] != nil
    }

    func start(_ project: RunnerProject, automatically: Bool = false) {
        guard processes[project.id] == nil else {
            return
        }

        switch RunnerMatcher.runner(for: project, among: [project], and: runningRunners) {
        case .matched:
            states[project.id] = .stopped
            return
        case .conflict:
            states[project.id] = .failed(
                "Runner identity conflicts with another running Amp process."
            )
            return
        case .none:
            break
        }

        if
            automatically,
            let lastStartAttempt = lastStartAttempts[project.id],
            Date().timeIntervalSince(lastStartAttempt) < 10
        {
            return
        }
        lastStartAttempts[project.id] = Date()

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            states[project.id] = .failed("Project directory no longer exists.")
            return
        }

        guard let ampExecutableURL = locateAmpExecutable() else {
            states[project.id] = .failed(
                "Amp CLI was not found. Install Amp in ~/.local/bin or a standard Homebrew location."
            )
            return
        }

        states[project.id] = .starting
        capturedData[project.id] = Data()

        guard let terminal = makePseudoTerminal() else {
            states[project.id] = .failed("Could not create a terminal for Amp.")
            return
        }

        let process = Process()
        process.executableURL = ampExecutableURL
        process.arguments = [
            "--no-tui",
            "--runner-id", project.runnerID,
            "--remote-control-terminal",
        ]
        process.currentDirectoryURL = project.directoryURL
        process.standardOutput = terminal.slave
        process.standardError = terminal.slave
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["FORCE_COLOR"] = "3"
        environment["NO_COLOR"] = nil
        process.environment = environment

        terminal.master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            DispatchQueue.main.async {
                self?.recordOutput(data, for: project.id)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                self?.processDidTerminate(terminatedProcess, projectID: project.id)
            }
        }

        processes[project.id] = process
        terminals[project.id] = terminal

        do {
            try process.run()
            projectIDsByProcessIdentifier[process.processIdentifier] = project.id
            states[project.id] = .running
            refreshRunningRunners()
        } catch {
            terminal.master.readabilityHandler = nil
            terminal.master.closeFile()
            terminal.slave.closeFile()
            processes[project.id] = nil
            terminals[project.id] = nil
            states[project.id] = .failed(error.localizedDescription)
        }
    }

    func migrate(_ runner: RunningRunner, to project: RunnerProject) {
        guard !isOwned(runner), migrationTasks[project.id] == nil else {
            return
        }

        states[project.id] = .starting
        migratingProcessIdentifiers[project.id] = runner.processIdentifier

        guard Darwin.kill(runner.processIdentifier, SIGTERM) == 0 else {
            if errno == ESRCH {
                completeMigration(of: runner, to: project)
            } else {
                migratingProcessIdentifiers[project.id] = nil
                states[project.id] = .failed("Could not stop the existing Amp runner.")
            }
            return
        }

        migrationTasks[project.id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<50 {
                guard !Task.isCancelled else {
                    return
                }
                if !processExists(runner.processIdentifier) {
                    completeMigration(of: runner, to: project)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard !Task.isCancelled else {
                return
            }
            migrationTasks[project.id] = nil
            migratingProcessIdentifiers[project.id] = nil
            states[project.id] = .failed("The existing Amp runner did not stop.")
        }
    }

    func stop(projectID: RunnerProject.ID) {
        if let migrationTask = migrationTasks.removeValue(forKey: projectID) {
            migrationTask.cancel()
            migratingProcessIdentifiers[projectID] = nil
            states[projectID] = .stopped
            return
        }

        guard let process = processes[projectID], process.isRunning else {
            states[projectID] = .stopped
            return
        }

        stoppingProjects.insert(projectID)
        states[projectID] = .stopping
        process.terminate()
    }

    func stop(_ runner: RunningRunner) {
        guard let projectID = projectIDsByProcessIdentifier[runner.processIdentifier] else {
            return
        }
        stop(projectID: projectID)
    }

    func stopAll() {
        for migrationTask in migrationTasks.values {
            migrationTask.cancel()
        }
        migrationTasks.removeAll()
        migratingProcessIdentifiers.removeAll()

        for (projectID, process) in processes where process.isRunning {
            stoppingProjects.insert(projectID)
            process.terminate()
        }
    }

    private func recordOutput(_ data: Data, for projectID: RunnerProject.ID) {
        var projectData = capturedData[projectID] ?? Data()
        projectData.append(data)
        if projectData.count > 50_000 {
            projectData.removeFirst(projectData.count - 50_000)
        }
        capturedData[projectID] = projectData

        capturedTerminalData.append(data)
        if capturedTerminalData.count > 200_000 {
            capturedTerminalData.removeFirst(capturedTerminalData.count - 200_000)
        }
        capturedTerminalOutput = String(decoding: capturedTerminalData, as: UTF8.self)
    }

    private func processDidTerminate(_ process: Process, projectID: RunnerProject.ID) {
        guard processes[projectID] === process else {
            return
        }

        terminals[projectID]?.master.readabilityHandler = nil
        terminals[projectID]?.master.closeFile()
        terminals[projectID]?.slave.closeFile()
        terminals[projectID] = nil
        processes[projectID] = nil
        projectIDsByProcessIdentifier[process.processIdentifier] = nil

        if stoppingProjects.remove(projectID) != nil || process.terminationStatus == 0 {
            states[projectID] = .stopped
        } else {
            let output = capturedData[projectID].map {
                String(decoding: $0, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let detail = output.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Amp exited with status \(process.terminationStatus)."
            states[projectID] = .failed(detail)
        }
        capturedData[projectID] = nil

        refreshRunningRunners()
    }

    private func completeMigration(of runner: RunningRunner, to project: RunnerProject) {
        guard migratingProcessIdentifiers[project.id] == runner.processIdentifier else {
            return
        }

        migrationTasks[project.id] = nil
        migratingProcessIdentifiers[project.id] = nil
        runningRunners.removeAll { $0.processIdentifier == runner.processIdentifier }
        start(project)
    }

    private func processExists(_ processIdentifier: Int32) -> Bool {
        if Darwin.kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
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

    private func locateAmpExecutable() -> URL? {
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
