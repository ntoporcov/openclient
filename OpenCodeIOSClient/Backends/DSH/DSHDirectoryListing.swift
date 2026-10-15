import Foundation

struct DSHDirectoryListing: Decodable {
    struct Entry: Decodable {
        let name: String
        let path: String
    }

    let path: String
    let home: String
    let entries: [Entry]

    static func searchPath(input: String, home: String) -> (path: String, partial: String?) {
        if input.isEmpty || input == "~" || input == "~/" { return (home, nil) }
        let absolute: String
        if input.hasPrefix("~/") { absolute = home + "/" + input.dropFirst(2) }
        else if input.hasPrefix("/") { absolute = input }
        else { absolute = home + "/" + input }
        let candidate = URL(fileURLWithPath: absolute).standardizedFileURL
        if input.hasSuffix("/") { return (candidate.path, nil) }
        return (candidate.deletingLastPathComponent().path, candidate.lastPathComponent)
    }

    func searchResult(partial: String?) -> BackendDirectorySearch {
        guard let partial else { return .init(directories: entries.map(\.path), selectedDirectory: path) }
        return .init(directories: entries.filter { $0.name.localizedCaseInsensitiveContains(partial) }.map(\.path),
            selectedDirectory: entries.first { $0.name == partial }?.path)
    }
}
