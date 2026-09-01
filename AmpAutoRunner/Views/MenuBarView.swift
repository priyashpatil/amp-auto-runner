import AppKit
import SwiftUI

struct RunnerDashboardView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var projects: ProjectStore
    @ObservedObject private var runners: RunnerManager
    @AppStorage("runnerLogsHeight") private var savedRunnerLogsHeight = 0.0
    @AppStorage("runnerLogsFontSize") private var interfaceFontSize = 13.0
    @State private var hoveredRunnerID: RunnerTableRow.ID?
    @State private var runnerLogsDragStart: CGFloat?
    @State private var runnerLogsDragHeight: CGFloat?
    @State private var sortOrder = [
        KeyPathComparator(
            \RunnerTableRow.name,
            comparator: String.Comparator.localizedStandard
        ),
    ]

    init(model: AppModel) {
        self.model = model
        projects = model.projects
        runners = model.runners
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            GeometryReader { geometry in
                if model.showsRunnerList, model.showsRunnerLogs {
                    splitLayout(in: geometry.size)
                } else if model.showsRunnerList {
                    content
                } else {
                    runnerLogsPane
                }
            }
        }
        .frame(minWidth: 600, minHeight: 320)
        .background(RunnerTheme.windowBackground)
        .preferredColorScheme(.dark)
    }

    private var runnerLogsPane: some View {
        RunnerLogsView(
            logs: runners.logs,
            isPresented: runnerLogsBinding,
            fontSize: interfaceFontSize
        )
    }

    private func splitLayout(in size: CGSize) -> some View {
        let dividerHeight: CGFloat = 9
        let minimumRunnerHeight: CGFloat = 96
        let minimumLogsHeight: CGFloat = 96
        let maximumLogsHeight = max(
            minimumLogsHeight,
            size.height - dividerHeight - minimumRunnerHeight
        )
        let defaultLogsHeight = (size.height - dividerHeight) / 2
        let requestedLogsHeight = runnerLogsDragHeight
            ?? (savedRunnerLogsHeight > 0
                ? CGFloat(savedRunnerLogsHeight)
                : defaultLogsHeight)
        let logsHeight = min(
            max(requestedLogsHeight, minimumLogsHeight),
            maximumLogsHeight
        )

        return VStack(spacing: 0) {
            content
                .frame(height: size.height - dividerHeight - logsHeight)

            runnerLogsDivider(
                currentHeight: logsHeight,
                minimumHeight: minimumLogsHeight,
                maximumHeight: maximumLogsHeight
            )

            runnerLogsPane
                .frame(height: logsHeight)
        }
    }

    private func runnerLogsDivider(
        currentHeight: CGFloat,
        minimumHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> some View {
        ZStack {
            RunnerTheme.panelBackground
            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 34, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .help("Drag to resize runner logs")
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeUpDown.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if runnerLogsDragStart == nil {
                        runnerLogsDragStart = currentHeight
                    }
                    guard let runnerLogsDragStart else {
                        return
                    }
                    let newHeight = runnerLogsDragStart - value.translation.height
                    runnerLogsDragHeight = min(
                        max(newHeight, minimumHeight),
                        maximumHeight
                    )
                }
                .onEnded { _ in
                    if let runnerLogsDragHeight {
                        savedRunnerLogsHeight = Double(runnerLogsDragHeight)
                    }
                    runnerLogsDragStart = nil
                    runnerLogsDragHeight = nil
                }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.19, green: 0.20, blue: 0.24),
                                    Color(red: 0.07, green: 0.075, blue: 0.10),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("RUNNERS")
                            .font(
                                .system(
                                    size: interfaceFontSize + 1,
                                    weight: .semibold,
                                    design: .monospaced
                                )
                            )
                            .lineLimit(1)
#if DEBUG
                        Text("DEBUG")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 3))
#endif
                    }
                    Text(runningSummary)
                        .font(
                            .system(
                                size: max(10, interfaceFontSize - 2),
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                headerControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RunnerTheme.panelBackground)
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            Button(action: chooseProject) {
                Label("Add Project", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add Project")
            .help("Add Project")

            Toggle(isOn: runnerListBinding) {
                Label("Runners", systemImage: "list.bullet")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityLabel(model.showsRunnerList ? "Hide Runners" : "Show Runners")
            .help(model.showsRunnerList ? "Hide Runners" : "Show Runners")

            Toggle(isOn: runnerLogsBinding) {
                Label("Logs", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityLabel(
                model.showsRunnerLogs ? "Hide Runner Logs" : "Show Runner Logs"
            )
            .help(model.showsRunnerLogs ? "Hide Runner Logs" : "Show Runner Logs")

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
        }
        .font(.system(size: interfaceFontSize))
        .controlSize(.large)
        .fixedSize()
    }

    private var runnerListBinding: Binding<Bool> {
        Binding(
            get: { model.showsRunnerList },
            set: model.setRunnerListVisible
        )
    }

    private var runnerLogsBinding: Binding<Bool> {
        Binding(
            get: { model.showsRunnerLogs },
            set: model.setRunnerLogsVisible
        )
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
        Table(
            of: RunnerTableRow.self,
            selection: hoverSelection,
            sortOrder: $sortOrder
        ) {
            TableColumn("") { row in
                RunnerControl(row: row, model: model, runners: runners)
                    .frame(maxWidth: .infinity)
            }
            .width(28)

            TableColumn("Project", value: \.name) { row in
                HStack(spacing: 7) {
                    Image(systemName: row.project == nil ? "terminal" : "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(row.name)
                        .font(
                            .system(
                                size: interfaceFontSize,
                                weight: .medium,
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                }
                .help(row.path ?? "Working directory unavailable")
            }
            .width(min: 110, ideal: 190)

            TableColumn("Runner ID", value: \.runnerID) { row in
                if let project = row.project, row.canEditRunnerID {
                    RunnerIDEditor(
                        project: project,
                        model: model,
                        fontSize: interfaceFontSize
                    )
                } else {
                    Text(row.runnerID)
                        .font(
                            .system(
                                size: max(10, interfaceFontSize - 1),
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                        .help(row.runnerID)
                }
            }
            .width(min: 130, ideal: 210)

            TableColumn("Status", value: \.statusLabel) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.statusColor)
                        .frame(width: 7, height: 7)
                    Text(row.statusLabel)
                        .font(
                            .system(
                                size: max(10, interfaceFontSize - 1),
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                }
            }
            .width(86)

            TableColumn("Auto Run", value: \.autoRunSortValue) { row in
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
            .width(64)

            TableColumn("") { row in
                if let project = row.project {
                    Button {
                        model.remove(project)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove runner")
                    .help("Remove runner")
                    .frame(maxWidth: .infinity)
                }
            }
            .width(28)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .onHover { isHovered in
                        if isHovered {
                            hoveredRunnerID = row.id
                        } else if hoveredRunnerID == row.id {
                            hoveredRunnerID = nil
                        }
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(RunnerTheme.listBackground)
    }

    private var hoverSelection: Binding<RunnerTableRow.ID?> {
        Binding(
            get: { hoveredRunnerID },
            set: { _ in }
        )
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

        return (managed + available + stopped).sorted(using: sortOrder)
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

    var autoRunSortValue: Int {
        project?.startsAutomatically == true ? 1 : 0
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
    let fontSize: Double

    @State private var runnerID: String
    @FocusState private var isFocused: Bool

    init(project: RunnerProject, model: AppModel, fontSize: Double) {
        self.project = project
        self.model = model
        self.fontSize = fontSize
        _runnerID = State(initialValue: project.runnerID)
    }

    var body: some View {
        TextField("Runner ID", text: $runnerID)
            .font(.system(size: max(10, fontSize - 1), design: .monospaced))
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
