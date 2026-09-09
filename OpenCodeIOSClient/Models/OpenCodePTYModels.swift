import Foundation

struct OpenCodePTY: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let command: String
    let args: [String]
    let cwd: String
    let status: String
    let pid: Int
    var exitCode: Int? = nil
}

struct OpenCodePTYCreateRequest: Encodable, Sendable {
    let command: String?
    let args: [String]?
    let cwd: String?
    let title: String?
    let env: [String: String]?

    init(
        command: String? = nil,
        args: [String]? = nil,
        cwd: String? = nil,
        title: String? = nil,
        env: [String: String]? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.title = title
        self.env = env
    }
}

struct OpenCodePTYUpdateRequest: Encodable, Sendable {
    struct Size: Encodable, Sendable {
        let rows: Int
        let cols: Int
    }

    let title: String?
    let size: Size?

    init(title: String? = nil, rows: Int? = nil, columns: Int? = nil) {
        self.title = title
        if let rows, let columns {
            size = Size(rows: rows, cols: columns)
        } else {
            size = nil
        }
    }
}

enum OpenCodePTYSocketEvent: Equatable, Sendable {
    case connected
    case closed(code: Int)
    case output(String, cursor: Int)
    case cursor(Int)
}
