import Foundation

struct RunnerProject: Codable, Equatable, Identifiable {
    let id: UUID
    let path: String
    var isServed: Bool

    init(
        id: UUID = UUID(),
        path: String,
        isServed: Bool = true
    ) {
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        self.id = id
        self.path = directoryURL.path
        self.isServed = isServed
    }

    var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var name: String {
        let name = directoryURL.lastPathComponent
        return name.isEmpty ? path : name
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case isServed
        case startsAutomatically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            path: try container.decode(String.self, forKey: .path),
            isServed: try container.decodeIfPresent(Bool.self, forKey: .isServed)
                ?? container.decodeIfPresent(Bool.self, forKey: .startsAutomatically)
                ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(isServed, forKey: .isServed)
    }
}
