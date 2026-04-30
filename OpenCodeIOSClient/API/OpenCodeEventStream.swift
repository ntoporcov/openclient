import Foundation

struct OpenCodeServerEvent: Sendable {
    let type: String
    let data: String
}

struct OpenCodeSSEParser {
    private(set) var eventType = "message"
    private(set) var dataLines: [String] = []

    mutating func process(line: String) -> [OpenCodeServerEvent] {
        var emitted: [OpenCodeServerEvent] = []

        if line.isEmpty {
            if let event = flush() {
                emitted.append(event)
            }
            return emitted
        }

        if line.hasPrefix(":") {
            return emitted
        }

        if line.hasPrefix("event:") {
            eventType = fieldValue(from: line, prefix: "event:")
            return emitted
        }

        if line.hasPrefix("data:") {
            let value = fieldValue(from: line, prefix: "data:")

            if !dataLines.isEmpty, value.first == "{" || value.first == "[" {
                if let event = flush() {
                    emitted.append(event)
                }
            }

            dataLines.append(value)
        }

        return emitted
    }

    private func fieldValue(from line: String, prefix: String) -> String {
        var value = String(line.dropFirst(prefix.count))
        if value.first == " " {
            value.removeFirst()
        }
        return value
    }

    private mutating func flush() -> OpenCodeServerEvent? {
        guard !dataLines.isEmpty else { return nil }
        defer {
            eventType = "message"
            dataLines.removeAll(keepingCapacity: true)
        }
        return OpenCodeServerEvent(type: eventType, data: dataLines.joined(separator: "\n"))
    }
}

enum OpenCodeEventStream {
    static func consume(
        client: OpenCodeAPIClient,
        url: URL,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeServerEvent) async -> Void
    ) async {
        do {
            await onStatus("stream connecting \(url.lastPathComponent)")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(basicAuthHeader(client: client), forHTTPHeaderField: "Authorization")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.timeoutInterval = TimeInterval.infinity

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = TimeInterval.infinity
            configuration.timeoutIntervalForResource = TimeInterval.infinity
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let streamSession = URLSession(configuration: configuration)
            defer {
                streamSession.invalidateAndCancel()
            }

            let (bytes, response) = try await streamSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                await onStatus("stream invalid response")
                return
            }

            guard (200 ..< 300).contains(http.statusCode) else {
                await onStatus("stream http \(http.statusCode)")
                return
            }

            await onStatus("stream open \(url.lastPathComponent)")

            var parser = OpenCodeSSEParser()

            for try await line in bytes.lines {
                if Task.isCancelled {
                    return
                }

                if let onRawLine {
                    await onRawLine(line)
                }

                for event in parser.process(line: line) {
                    await onEvent(event)
                }
            }
        } catch {
            await onStatus("stream error")
            return
        }
    }

    private static func basicAuthHeader(client: OpenCodeAPIClient) -> String {
        let credentials = "\(client.config.username):\(client.config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
