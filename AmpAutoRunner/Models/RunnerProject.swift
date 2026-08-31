import Foundation

struct RunnerProject: Codable, Equatable, Identifiable {
    let id: UUID
    let path: String
    var runnerID: String
    var startsAutomatically: Bool

    init(
        id: UUID = UUID(),
        path: String,
        runnerID: String? = nil,
        startsAutomatically: Bool = true
    ) {
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        self.id = id
        self.path = directoryURL.path
        self.runnerID = runnerID ?? Self.makeRunnerID(for: directoryURL, id: id)
        self.startsAutomatically = startsAutomatically
    }

    var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var name: String {
        let name = directoryURL.lastPathComponent
        return name.isEmpty ? path : name
    }

    static func makeRunnerID(for directoryURL: URL, id: UUID) -> String {
        let normalizedName = normalizedRunnerID(directoryURL.lastPathComponent) ?? "amp-runner"
        let suffix = id.uuidString.prefix(6).lowercased()
        let maximumNameLength = 63 - suffix.count - 1
        let shortenedName = normalizedName.prefix(maximumNameLength)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "\(shortenedName)-\(suffix)"
    }

    static func normalizedRunnerID(_ runnerID: String) -> String? {
        let foldedRunnerID = runnerID
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        let normalizedCharacters = foldedRunnerID.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122:
                return Character(String(scalar))
            default:
                return "-"
            }
        }

        let normalizedName = String(normalizedCharacters)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let shortenedName = normalizedName.prefix(63)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return shortenedName.isEmpty ? nil : shortenedName
    }
}
