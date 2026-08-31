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

        self.projects = projects
    }

    @discardableResult
    func add(directoryURL: URL, runnerID: String? = nil) -> RunnerProject {
        let candidate = RunnerProject(path: directoryURL.path, runnerID: runnerID)

        if let index = projects.firstIndex(where: { $0.path == candidate.path }) {
            if let runnerID, projects[index].runnerID != runnerID {
                projects[index].runnerID = runnerID
                save()
            }
            return projects[index]
        }

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
}
