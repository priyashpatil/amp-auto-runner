import Combine
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [RunnerProject]

    private static let storageKey = "runnerProjects"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        guard
            let data = defaults.data(forKey: Self.storageKey),
            let projects = try? JSONDecoder().decode([RunnerProject].self, from: data)
        else {
            self.projects = []
            return
        }

        self.projects = Self.projectsWithUniqueRunnerIDs(projects)
        if self.projects != projects {
            save()
        }
    }

    @discardableResult
    func add(directoryURL: URL, runnerID: String? = nil) -> RunnerProject {
        var candidate = RunnerProject(path: directoryURL.path, runnerID: runnerID)

        if let index = projects.firstIndex(where: { $0.path == candidate.path }) {
            if let runnerID, projects[index].runnerID != runnerID {
                let usedRunnerIDs = Set(
                    projects.enumerated().compactMap { projectIndex, project in
                        projectIndex == index ? nil : project.runnerID
                    }
                )
                projects[index].runnerID = Self.uniqueRunnerID(
                    runnerID,
                    excluding: usedRunnerIDs
                )
                save()
            }
            return projects[index]
        }

        candidate.runnerID = Self.uniqueRunnerID(
            candidate.runnerID,
            excluding: Set(projects.map(\.runnerID))
        )
        projects.append(candidate)
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        return candidate
    }

    func remove(id: RunnerProject.ID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func setStartsAutomatically(_ startsAutomatically: Bool, for id: RunnerProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        projects[index].startsAutomatically = startsAutomatically
        save()
    }

    @discardableResult
    func setRunnerID(_ runnerID: String, for id: RunnerProject.ID) -> String? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        guard
            let normalizedRunnerID = RunnerProject.normalizedRunnerID(runnerID),
            !projects.contains(where: { $0.id != id && $0.runnerID == normalizedRunnerID })
        else {
            return projects[index].runnerID
        }

        projects[index].runnerID = normalizedRunnerID
        save()
        return normalizedRunnerID
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else {
            return
        }

        defaults.set(data, forKey: Self.storageKey)
    }

    private static func projectsWithUniqueRunnerIDs(
        _ projects: [RunnerProject]
    ) -> [RunnerProject] {
        var usedRunnerIDs: Set<String> = []

        return projects.map { project in
            var project = project
            project.runnerID = uniqueRunnerID(project.runnerID, excluding: usedRunnerIDs)
            usedRunnerIDs.insert(project.runnerID)
            return project
        }
    }

    private static func uniqueRunnerID(
        _ preferredRunnerID: String,
        excluding usedRunnerIDs: Set<String>
    ) -> String {
        guard usedRunnerIDs.contains(preferredRunnerID) else {
            return preferredRunnerID
        }

        let baseRunnerID = RunnerProject.normalizedRunnerID(preferredRunnerID) ?? "amp-runner"
        var suffixNumber = 2

        while true {
            let suffix = "-\(suffixNumber)"
            let maximumBaseLength = 63 - suffix.count
            let shortenedBase = baseRunnerID.prefix(maximumBaseLength)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let candidate = "\(shortenedBase)\(suffix)"
            if !usedRunnerIDs.contains(candidate) {
                return candidate
            }
            suffixNumber += 1
        }
    }
}
