import AppKit
import SwiftUI

struct RunnerDashboardView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var projects: ProjectStore
    @ObservedObject private var runners: RunnerManager
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
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
        launchAtLogin = model.launchAtLogin
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if showsLaunchAtLoginNotice {
                launchAtLoginNotice
                Divider()
            }

            if let errorMessage = runners.errorMessage {
                runnerErrorNotice(errorMessage)
                Divider()
            }

            GeometryReader { geometry in
                if model.showsRunnerLogs {
                    splitLayout(in: geometry.size)
                } else {
                    content
                }
            }
        }
        .frame(minWidth: 600, minHeight: 320)
        .background(RunnerTheme.windowBackground)
        .preferredColorScheme(.dark)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            launchAtLogin.refresh()
        }
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
                    Text(runners.runnerID)
                        .font(
                            .system(
                                size: max(10, interfaceFontSize - 2),
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(runners.runnerID)
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
            runnerControl

            Button(action: chooseProject) {
                Label("Add Directory", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add Directory")
            .help("Add a directory to the runner")

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

    @ViewBuilder
    private var runnerControl: some View {
        if runners.isRunning {
            Button {
                model.stopRunner()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .help("Stop the shared runner")
        } else {
            switch runners.state {
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28)
            case .stopped, .failed, .running:
                Button {
                    model.startRunner()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!projects.projects.contains(where: \.isServed))
                .help("Start one runner for all served directories")
            }
        }
    }

    private var showsLaunchAtLoginNotice: Bool {
        !launchAtLogin.isEnabled
    }

    private var launchAtLoginNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(launchAtLoginNoticeMessage)
                .font(
                    .system(
                        size: max(10, interfaceFontSize - 2),
                        design: .monospaced
                    )
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if launchAtLogin.requiresApproval {
                Button("Open Login Items") {
                    launchAtLogin.openLoginItemsSettings()
                }
                .help("Open Login Items in System Settings")
            } else {
                Button(launchAtLogin.message == nil ? "Enable" : "Try Again") {
                    launchAtLogin.setEnabled(true)
                }
                .disabled(!AppIdentity.supportsLaunchAtLogin)
                .help("Enable Launch at Login")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.08))
    }

    private var launchAtLoginNoticeMessage: String {
        if launchAtLogin.requiresApproval {
            return "Launch at Login needs approval. The runner won’t resume until it is allowed in System Settings."
        }
        if let message = launchAtLogin.message {
            return "Launch at Login couldn’t be enabled. \(message)"
        }
        return "Launch at Login is off. The runner won’t resume after your next login."
    }

    private func runnerErrorNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(message)
                .font(
                    .system(
                        size: max(10, interfaceFontSize - 2),
                        design: .monospaced
                    )
                )
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(message)

            Spacer(minLength: 8)

            Button("Dismiss") {
                runners.clearError()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.08))
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
                Text("Finding the local runner…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tableRows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No directories configured")
                    .font(.headline)
                Text("Add directories to serve them from one Amp runner.")
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
            TableColumn("Directory", value: \.name) { row in
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
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
                .help(row.project.path)
            }
            .width(min: 130, ideal: 210)

            TableColumn("Path", value: \.path) { row in
                Text(row.path)
                    .font(
                        .system(
                            size: max(10, interfaceFontSize - 1),
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)
                    .help(row.path)
            }
            .width(min: 190, ideal: 320)

            TableColumn("Served", value: \.servedSortValue) { row in
                HStack {
                    Spacer(minLength: 0)
                    Toggle("Serve Directory", isOn: servedBinding(for: row.project))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(model.pendingProjectIDs.contains(row.project.id))
                        .help("Make this directory available through the shared runner")
                    Spacer(minLength: 0)
                }
            }
            .width(64)

            TableColumn("") { row in
                Button {
                    model.remove(row.project)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.pendingProjectIDs.contains(row.project.id))
                .accessibilityLabel("Remove directory")
                .help("Remove directory")
                .frame(maxWidth: .infinity)
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
        panel.title = "Add Directory"
        panel.message = "Choose a directory for the shared Amp runner to serve."
        panel.prompt = "Add Directory"
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
        projects.projects.map { project in
            RunnerTableRow(
                id: project.id.uuidString,
                project: project
            )
        }
        .sorted(using: sortOrder)
    }

    private func servedBinding(for project: RunnerProject) -> Binding<Bool> {
        Binding(
            get: {
                projects.projects.first(where: { $0.id == project.id })?.isServed == true
            },
            set: { isServed in
                model.setIsServed(isServed, for: project)
            }
        )
    }

    private var runningSummary: String {
        let servedCount = projects.projects.filter(\.isServed).count
        let directorySummary = servedCount == 1 ? "1 directory" : "\(servedCount) directories"
        return "\(runnerStatusLabel) · \(directorySummary)"
    }

    private var runnerStatusLabel: String {
        switch runners.state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}

private struct RunnerTableRow: Identifiable {
    let id: String
    let project: RunnerProject

    var name: String {
        project.name
    }

    var path: String {
        project.path
    }

    var servedSortValue: Int {
        project.isServed ? 1 : 0
    }
}
