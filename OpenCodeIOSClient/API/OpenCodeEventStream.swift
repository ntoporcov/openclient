import Foundation

struct OpenCodeServerEvent: Sendable {
    let type: String
    let data: String
    let id: String?
    let retry: Int?
}

struct OpenCodeSSEParser {
    private(set) var eventType = "message"
    private(set) var dataLines: [String] = []
    private(set) var eventID: String?
    private(set) var retry: Int?

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

        if line.hasPrefix("id:") {
            eventID = fieldValue(from: line, prefix: "id:")
            return emitted
        }

        if line.hasPrefix("retry:") {
            retry = Int(fieldValue(from: line, prefix: "retry:"))
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
        return OpenCodeServerEvent(type: eventType, data: dataLines.joined(separator: "\n"), id: eventID, retry: retry)
    }
}

struct OpenCodeSSELineDecoder {
    private var buffer: [UInt8] = []
    private var followsCarriageReturn = false
    private var isFirstLine = true

    mutating func process(byte: UInt8) -> String? {
        if followsCarriageReturn {
            followsCarriageReturn = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else {
            buffer.append(byte)
            return nil
        }
        followsCarriageReturn = byte == 13
        var line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }
        return line
    }
}

enum OpenCodeEventStream {
    private static let streamYieldInterval: TimeInterval = 0.008

    static func consume(
        client: OpenCodeAPIClient,
        url: URL,
        onStatus: @escaping @Sendable (String) async -> Void,
        onActivity: (@Sendable () async -> Void)? = nil,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeServerEvent) async -> Void
    ) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = client.session.configuration.protocolClasses
        configuration.timeoutIntervalForRequest = TimeInterval.infinity
        configuration.timeoutIntervalForResource = TimeInterval.infinity
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let streamSession = URLSession(configuration: configuration)
        defer { streamSession.invalidateAndCancel() }

        await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                await onStatus("stream connecting \(url.lastPathComponent)")
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue(basicAuthHeader(client: client), forHTTPHeaderField: "Authorization")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.timeoutInterval = TimeInterval.infinity

                let (bytes, response) = try await streamSession.bytes(for: request)
                try Task.checkCancellation()
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
                var lineDecoder = OpenCodeSSELineDecoder()
                var lastYieldAt = Date.now

                // AsyncBytes.lines omits empty lines, but SSE needs them to dispatch a frame.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard let line = lineDecoder.process(byte: byte) else { continue }

                    await onActivity?()
                    if let onRawLine {
                        await onRawLine(line)
                    }

                    for event in parser.process(line: line) {
                        try Task.checkCancellation()
                        await onEvent(event)
                        if Date.now.timeIntervalSince(lastYieldAt) >= Self.streamYieldInterval {
                            lastYieldAt = Date.now
                            await Task.yield()
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await onStatus("stream error")
            }
        } onCancel: {
            // AsyncBytes can be suspended waiting for a line from a silent server.
            streamSession.invalidateAndCancel()
        }
    }

    private static func basicAuthHeader(client: OpenCodeAPIClient) -> String {
        let credentials = "\(client.config.username):\(client.config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
