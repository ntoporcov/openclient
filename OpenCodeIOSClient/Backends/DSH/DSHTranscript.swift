import Foundation

struct DSHSessionEvent: Codable, Equatable, Sendable {
    let type: String
    let seq: Int
    let time: Double
    let data: DSHJSON
}

/// Session-local wire projection. Durable sequence numbers and process-local
/// assistant indices are separate cursors; neither may advance the other.
struct DSHTranscript: Sendable {
    let sessionID: String
    private(set) var cursor = -1
    private(set) var hasMore = false
    private(set) var records: [Int: DSHSessionEvent] = [:]
    private(set) var messages: [OpenCodeMessageEnvelope] = []
    private var attempt: Attempt?
    private var revision: Int?

    struct Attempt: Sendable {
        let id: String
        let turn: Int
        let step: Int
        let startedAfterSeq: Int
        var nextIndex: Int
        var blocks: [Int: DSHJSON] = [:]
    }

    enum ContinuityError: Error { case gap, invalidFrame }

    mutating func apply(_ value: DSHJSON) throws -> [OpenCodeTypedEvent] {
        let previous = messages
        switch value[dsh: "type"].dshString {
        case "snapshot":
            guard value[dsh: "header"][dsh: "id"].dshString == sessionID,
                  let cut = value[dsh: "cursor"].intValue else { throw ContinuityError.invalidFrame }
            let decoded = try Self.events(value[dsh: "records"])
            try Self.validate(decoded, through: cut)
            records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.seq, $0) })
            cursor = cut
            hasMore = value[dsh: "hasMore"].dshBool
            attempt = nil
            let baseline = value[dsh: "assistantStream"]
            revision = baseline[dsh: "revision"].intValue
            let active = baseline[dsh: "activeAttempt"]
            if active != .null {
                attempt = try Self.makeAttempt(active)
                for record in active[dsh: "stream"].dshArray { try applyCompact(record) }
            }
        case "event":
            let event = try value[dsh: "event"].dshDecode(DSHSessionEvent.self)
            if event.seq <= cursor { return [] }
            guard event.seq == cursor + 1 else { throw ContinuityError.gap }
            records[event.seq] = event
            cursor = event.seq
        case "assistant-stream":
            let frame = value[dsh: "frame"]
            guard let nextRevision = frame[dsh: "revision"].intValue else { throw ContinuityError.invalidFrame }
            if let revision, nextRevision <= revision { return [] }
            if let revision, nextRevision != revision + 1 { throw ContinuityError.gap }
            revision = nextRevision
            switch frame[dsh: "type"].dshString {
            case "start": attempt = try Self.makeAttempt(frame)
            case "chunk":
                guard attempt?.id == frame[dsh: "attemptId"].dshString else { break }
                guard frame[dsh: "index"].intValue == attempt?.nextIndex else { throw ContinuityError.gap }
                try applyChunk(frame[dsh: "chunk"])
                attempt?.nextIndex += 1
            case "end":
                guard attempt?.id == frame[dsh: "attemptId"].dshString else { break }
                guard frame[dsh: "index"].intValue == attempt?.nextIndex else { throw ContinuityError.gap }
                let outcome = frame[dsh: "outcome"]
                if outcome[dsh: "kind"].dshString == "committed" {
                    guard let seq = outcome[dsh: "seq"].intValue, records[seq] != nil else { throw ContinuityError.gap }
                }
                attempt = nil
            default: throw ContinuityError.invalidFrame
            }
        default: throw ContinuityError.invalidFrame
        }
        messages = project()
        return Self.changes(from: previous, to: messages, sessionID: sessionID)
    }

    mutating func prepend(_ page: DSHJSON) throws {
        let older = try Self.events(page[dsh: "records"])
        if let first = records.keys.min(), let last = older.last {
            guard last.seq == first - 1 else { throw ContinuityError.gap }
        }
        if let last = older.last { try Self.validate(older, through: last.seq) }
        for event in older { records[event.seq] = event }
        hasMore = page[dsh: "hasMore"].dshBool
        messages = project()
    }

    private static func events(_ value: DSHJSON) throws -> [DSHSessionEvent] {
        guard let records = value.arrayValue else { throw ContinuityError.invalidFrame }
        return try records.map {
            guard $0[dsh: "type"].dshString == "event" else { throw ContinuityError.invalidFrame }
            return try $0[dsh: "event"].dshDecode()
        }
    }

    private static func validate(_ events: [DSHSessionEvent], through cursor: Int) throws {
        guard events.last?.seq == cursor || (events.isEmpty && cursor == -1) else { throw ContinuityError.gap }
        for (a, b) in zip(events, events.dropFirst()) where b.seq != a.seq + 1 { throw ContinuityError.gap }
    }

    private static func makeAttempt(_ value: DSHJSON) throws -> Attempt {
        guard let id = value[dsh: "attemptId"].dshString,
              let turn = value[dsh: "turn"].intValue,
              let step = value[dsh: "step"].intValue,
              let seq = value[dsh: "startedAfterSeq"].intValue else { throw ContinuityError.invalidFrame }
        return Attempt(id: id, turn: turn, step: step, startedAfterSeq: seq,
                       nextIndex: value[dsh: "nextIndex"].intValue ?? 0)
    }

    private mutating func applyCompact(_ record: DSHJSON) throws {
        switch record[dsh: "type"].dshString {
        case "chunk": try applyChunk(record[dsh: "chunk"])
        case "text-chunks", "reasoning-chunks":
            try applyChunk(.object([
                "type": .string(record[dsh: "type"].dshString == "text-chunks" ? "text-delta" : "reasoning-delta"),
                "index": record[dsh: "index"],
                "text": .string(record[dsh: "texts"].dshArray.compactMap(\.dshString).joined())
            ]))
        case "tool-call-chunks":
            try applyChunk(.object([
                "type": .string("tool-call-delta"), "index": record[dsh: "index"],
                "id": record[dsh: "id"], "name": record[dsh: "name"],
                "argumentsDelta": .string(record[dsh: "args"].dshArray.compactMap(\.dshString).joined())
            ]))
        default: throw ContinuityError.invalidFrame
        }
    }

    private mutating func applyChunk(_ chunk: DSHJSON) throws {
        let type = chunk[dsh: "type"].dshString
        if type == "usage" || type == "finish" { return }
        guard let index = chunk[dsh: "index"].intValue, index >= 0 else { throw ContinuityError.invalidFrame }
        switch type {
        case "block-start":
            attempt?.blocks[index] = .object(["type": chunk[dsh: "blockType"], "text": .string("")])
        case "text-delta", "reasoning-delta":
            let expected = type == "text-delta" ? "text" : "reasoning"
            guard let block = attempt?.blocks[index], block[dsh: "type"].dshString == expected,
                  let text = chunk[dsh: "text"].dshString else { throw ContinuityError.invalidFrame }
            attempt?.blocks[index] = .object(["type": .string(expected), "text": .string((block[dsh: "text"].dshString ?? "") + text)])
        case "tool-call-delta":
            var fields = attempt?.blocks[index]?.objectValue ?? [:]
            fields["type"] = .string("tool-call")
            fields["id"] = chunk[dsh: "id"]
            if chunk[dsh: "name"] != .null { fields["name"] = chunk[dsh: "name"] }
            fields["arguments"] = .string((fields["arguments"]?.dshString ?? "") + (chunk[dsh: "argumentsDelta"].dshString ?? ""))
            attempt?.blocks[index] = .object(fields)
        case "block-end": attempt?.blocks[index] = chunk[dsh: "block"]
        default: throw ContinuityError.invalidFrame
        }
    }

    private func assistantID(turn: Int, step: Int) -> String { "dsh:\(sessionID):assistant:\(turn):\(step)" }

    private func project() -> [OpenCodeMessageEnvelope] {
        var output: [OpenCodeMessageEnvelope] = []
        var results: [String: DSHJSON] = [:]
        var lastUser: String?
        for event in records.values.sorted(by: { $0.seq < $1.seq }) {
            let data = event.data
            if event.type == "tool/result", let call = data[dsh: "message"][dsh: "callId"].dshString {
                results[call] = data
                continue
            }
            if event.type == "user/message" {
                // Runtime context, skill catalogs, and other injected input are not human bubbles.
                guard data[dsh: "source"][dsh: "kind"].dshString == "user" else { continue }
                let id = data[dsh: "source"][dsh: "rpcId"].dshString ?? data[dsh: "id"].dshString ?? "dsh:\(sessionID):user:\(event.seq)"
                lastUser = id
                output.append(envelope(id: id, role: "user", blocks: data[dsh: "content"].dshArray,
                                       time: event.time, completed: event.time, parent: nil))
            } else if event.type == "assistant/message" {
                let id = assistantID(turn: data[dsh: "turn"].intValue ?? 0, step: data[dsh: "step"].intValue ?? event.seq)
                let message = data[dsh: "message"]
                let source = message[dsh: "source"]
                let model: OpenCodeMessageModelReference? = if let provider = source[dsh: "provider"].dshString,
                    let model = source[dsh: "model"].dshString { .init(providerID: provider, modelID: model, variant: nil) } else { nil }
                output.append(envelope(id: id, role: "assistant", blocks: message[dsh: "content"].dshArray,
                    time: event.time, completed: event.time, parent: lastUser, model: model))
            }
        }
        if let attempt {
            let id = assistantID(turn: attempt.turn, step: attempt.step)
            // A committed message wins over the transient copy even before its end frame.
            if !output.contains(where: { $0.id == id }) {
                let time = (records[attempt.startedAfterSeq]?.time ?? output.last?.info.time?.created ?? 0) + 0.1
                output.append(envelope(id: id, role: "assistant", blocks: attempt.blocks.sorted(by: { $0.key < $1.key }).map(\.value),
                    time: time, completed: nil, parent: lastUser))
            }
        }
        for i in output.indices {
            output[i].parts = output[i].parts.map { part in
                guard let call = part.callID, let result = results[call] else { return part }
                let message = result[dsh: "message"]
                let text = message[dsh: "content"].dshArray.compactMap { $0[dsh: "text"].dshString }.joined(separator: "\n")
                return OpenCodePart(id: part.id, messageID: part.messageID, sessionID: sessionID, type: "tool",
                    mime: nil, filename: nil, url: nil, reason: nil, tool: part.tool, callID: call,
                    state: .init(status: message[dsh: "isError"].dshBool ? "error" : "completed", title: part.tool,
                        error: result[dsh: "error"][dsh: "reason"].dshString, input: part.state?.input,
                        output: text, metadata: nil, raw: part.state?.raw), text: nil)
            }
        }
        return output
    }

    private func envelope(id: String, role: String, blocks: [DSHJSON], time: Double,
                          completed: Double?, parent: String?, model: OpenCodeMessageModelReference? = nil) -> OpenCodeMessageEnvelope {
        let info = OpenCodeMessage(id: id, role: role, sessionID: sessionID,
            time: .init(created: time, completed: completed), agent: nil, model: model,
            parentID: parent, finish: completed == nil ? nil : "stop")
        let parts = blocks.enumerated().compactMap { index, block -> OpenCodePart? in
            guard let type = block[dsh: "type"].dshString else { return nil }
            let call = block[dsh: "id"].dshString
            let tool = block[dsh: "name"].dshString
            let raw = block[dsh: "arguments"].dshString
            let input = raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(OpenCodeToolInput.self, from: $0) }
            guard ["text", "reasoning", "tool-call"].contains(type) else { return nil }
            return OpenCodePart(id: "\(id):\(index)", messageID: id, sessionID: sessionID,
                type: type == "tool-call" ? "tool" : type, mime: nil, filename: nil, url: nil, reason: nil,
                tool: tool, callID: call,
                state: type == "tool-call" ? .init(status: "running", title: tool, error: nil, input: input,
                                                  output: nil, metadata: nil, raw: raw) : nil,
                text: block[dsh: "text"].dshString,
                time: .init(start: time, end: completed))
        }
        return .init(info: info, parts: parts)
    }

    static func changes(from old: [OpenCodeMessageEnvelope], to new: [OpenCodeMessageEnvelope], sessionID: String) -> [OpenCodeTypedEvent] {
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let after = Set(new.map(\.id))
        var events = old.filter { !after.contains($0.id) }.map { OpenCodeTypedEvent.messageRemoved(sessionID: sessionID, messageID: $0.id) }
        for message in new {
            let previous = before[message.id]
            if previous?.info != message.info { events.append(.messageUpdated(message.info)) }
            let partIDs = Set(message.parts.compactMap(\.id))
            for part in previous?.parts ?? [] {
                if let id = part.id, !partIDs.contains(id) { events.append(.messagePartRemoved(messageID: message.id, partID: id)) }
            }
            for part in message.parts where previous?.parts.contains(part) != true { events.append(.messagePartUpdated(part)) }
        }
        return events
    }
}
