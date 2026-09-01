import AppKit
import SwiftUI

struct RunnerDashboardView: View {
    private let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var projects: ProjectStore
    @ObservedObject private var runners: RunnerManager
    @ObservedObject private var launchAtLogin: LaunchAtLoginController

    init(model: AppModel) {
        self.model = model
        projects = model.projects
        runners = model.runners
        launchAtLogin = model.launchAtLogin
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Runners")
                        .font(.title2.weight(.semibold))
                    Text(runningSummary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: chooseProject) {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    openWindow(id: "runner-logs")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Runner Logs", systemImage: "terminal")
                }
                .buttonStyle(.bordered)

                Divider()
                    .frame(height: 22)

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: launchAtLogin.setEnabled
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            }

            if let message = launchAtLogin.message {
                HStack(spacing: 8) {
                    Spacer()
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)

                    if launchAtLogin.requiresApproval {
                        Button("Open Login Items") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(20)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            launchAtLogin.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !runners.hasCompletedInitialScan {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding local runners…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tableRows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No runners detected")
                    .font(.headline)
                Text("Add a project folder to start its runner.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            runnerTable(tableRows)
        }
    }

    private func runnerTable(_ rows: [RunnerTableRow]) -> some View {
        Table(rows) {
            TableColumn("") { row in
                RunnerControl(row: row, model: model, runners: runners)
                    .frame(maxWidth: .infinity)
            }
            .width(28)

            TableColumn("Project") { row in
                HStack(spacing: 7) {
                    Image(systemName: row.project == nil ? "terminal" : "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .help(row.path ?? "Working directory unavailable")
            }
            .width(min: 150, ideal: 210)

            TableColumn("Runner ID") { row in
                if let project = row.project, row.canEditRunnerID {
                    RunnerIDEditor(project: project, model: model)
                } else {
                    Text(row.runnerID)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(row.runnerID)
                }
            }
            .width(min: 170, ideal: 230)

            TableColumn("Status") { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.statusColor)
                        .frame(width: 7, height: 7)
                    Text(row.statusLabel)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .width(100)

            TableColumn("Auto Run") { row in
                HStack {
                    Spacer(minLength: 0)
                    Toggle("Start Automatically", isOn: autoStartBinding(for: row))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(row.project == nil && row.path == nil)
                        .help("Start this runner when Amp Auto Runner launches")
                    Spacer(minLength: 0)
                }
            }
            .width(72)

            TableColumn("") { row in
                if let project = row.project {
                    Button("Remove") {
                        model.remove(project)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove runner")
                    .frame(maxWidth: .infinity)
                }
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Add Project"
        panel.message = "Choose the project folder where Amp should run."
        panel.prompt = "Add Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let directoryURL = panel.url else {
                return
            }

            Task { @MainActor in
                model.addProject(directoryURL: directoryURL)
            }
        }
    }

    private var tableRows: [RunnerTableRow] {
        let managed = runners.runningRunners.compactMap { runner -> RunnerTableRow? in
            guard let project = model.project(for: runner) else {
                return nil
            }
            return RunnerTableRow(
                id: "running-\(runner.processIdentifier)",
                runner: runner,
                project: project,
                state: runners.state(for: project)
            )
        }
        let available = runners.runningRunners.compactMap { runner -> RunnerTableRow? in
            guard !model.isManaged(runner) else {
                return nil
            }
            return RunnerTableRow(
                id: "available-\(runner.processIdentifier)",
                runner: runner,
                project: nil,
                state: .running
            )
        }
        let stopped = projects.projects.compactMap { project -> RunnerTableRow? in
            guard runners.runningRunner(for: project) == nil else {
                return nil
            }
            return RunnerTableRow(
                id: "saved-\(project.id.uuidString)",
                runner: nil,
                project: project,
                state: runners.state(for: project)
            )
        }

        return (managed + available + stopped).sorted { left, right in
            let leftPriority = priority(of: left)
            let rightPriority = priority(of: right)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private func startsAutomatically(_ row: RunnerTableRow) -> Bool {
        guard let project = row.project else {
            return false
        }
        return projects.projects.first(where: { $0.id == project.id })?
            .startsAutomatically == true
    }

    private func priority(of row: RunnerTableRow) -> Int {
        if startsAutomatically(row) {
            return 0
        }
        if row.runner != nil || row.state == .starting || row.state == .running {
            return 1
        }
        return 2
    }

    private func autoStartBinding(for row: RunnerTableRow) -> Binding<Bool> {
        Binding(
            get: {
                if let project = row.project {
                    return projects.projects.first(where: { $0.id == project.id })?
                        .startsAutomatically == true
                }
                return row.runner.map(model.autoStarts) == true
            },
            set: { autoStarts in
                if let project = row.project {
                    model.setAutoStarts(autoStarts, for: project)
                } else if let runner = row.runner {
                    model.setAutoStarts(autoStarts, for: runner)
                }
            }
        )
    }

    private var runningSummary: String {
        let rows = tableRows
        let runningCount = rows.filter { $0.runner != nil || $0.state == .running }.count
        let totalSummary = rows.count == 1 ? "1 runner" : "\(rows.count) total"
        return "\(runningCount) running · \(totalSummary)"
    }
}

private struct RunnerTableRow: Identifiable {
    let id: String
    let runner: RunningRunner?
    let project: RunnerProject?
    let state: RunnerState

    var name: String {
        runner?.projectName ?? project?.name ?? "Unknown"
    }

    var path: String? {
        runner?.path ?? project?.path
    }

    var runnerID: String {
        runner?.runnerID ?? project?.runnerID ?? "—"
    }

    var canEditRunnerID: Bool {
        guard project != nil, runner == nil else {
            return false
        }
        return state != .starting && state != .stopping && state != .running
    }

    var statusLabel: String {
        if state == .starting {
            return "Starting"
        }
        if state == .stopping {
            return "Stopping"
        }
        if runner != nil {
            return project == nil ? "Available" : "Running"
        }

        switch state {
        case .stopped:
            return "Stopped"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        case .starting, .stopping:
            return "Working"
        }
    }

    var statusColor: Color {
        if state == .starting || state == .stopping {
            return .orange
        }
        if runner != nil {
            return project == nil ? .secondary : .green
        }

        switch state {
        case .running:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .secondary
        case .starting, .stopping:
            return .orange
        }
    }
}

private struct RunnerIDEditor: View {
    let project: RunnerProject
    let model: AppModel

    @State private var runnerID: String
    @FocusState private var isFocused: Bool

    init(project: RunnerProject, model: AppModel) {
        self.project = project
        self.model = model
        _runnerID = State(initialValue: project.runnerID)
    }

    var body: some View {
        TextField("Runner ID", text: $runnerID)
            .font(.caption.monospaced())
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(save)
            .onChange(of: isFocused) { _, isFocused in
                if !isFocused {
                    save()
                }
            }
            .onChange(of: project.runnerID) { _, runnerID in
                if !isFocused {
                    self.runnerID = runnerID
                }
            }
    }

    private func save() {
        runnerID = model.setRunnerID(runnerID, for: project)
    }
}

private struct RunnerControl: View {
    let row: RunnerTableRow
    let model: AppModel
    let runners: RunnerManager

    @ViewBuilder
    var body: some View {
        if let runner = row.runner, runners.isOwned(runner) {
            Button {
                model.stop(runner)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop runner")
        } else if let project = row.project, row.runner == nil {
            switch row.state {
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
            case .running:
                Button {
                    runners.stop(projectID: project.id)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop runner")
            case .stopped, .failed:
                Button {
                    runners.start(project)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start runner")
            }
        }
    }
}
