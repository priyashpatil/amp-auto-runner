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
    func add(directoryURL: URL, isServed: Bool = true) -> RunnerProject {
        let candidate = RunnerProject(path: directoryURL.path, isServed: isServed)

        if let index = projects.firstIndex(where: { $0.path == candidate.path }) {
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

    func setIsServed(_ isServed: Bool, for id: RunnerProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        projects[index].isServed = isServed
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else {
            return
        }

        defaults.set(data, forKey: Self.storageKey)
    }
}
