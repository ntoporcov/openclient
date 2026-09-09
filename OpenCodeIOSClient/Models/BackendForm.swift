import Foundation

/// The shared session/integration contract from next-17155 schema/src/form.ts.
struct BackendForm: Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let title: String
    var metadata: [String: OpenCodeJSONValue]? = nil
    let fields: [BackendFormField]

    var key: BackendFormKey { .init(sessionID: sessionID, formID: id) }
    var contract: BackendFormContract { .init(fields: fields) }
}

struct BackendFormKey: Hashable, Sendable {
    let sessionID: String
    let formID: String
}

enum BackendFormValue: Equatable, Codable, Sendable {
    case string(String), number(Double), boolean(Bool), strings([String])

    init(jsonValue: OpenCodeJSONValue) throws {
        switch jsonValue {
        case .string(let value): self = .string(value)
        case .number(let value) where value.isFinite: self = .number(value)
        case .bool(let value): self = .boolean(value)
        case .array(let values):
            let strings = values.compactMap(\.v2ConfigurationString)
            guard strings.count == values.count else { throw BackendFormError.invalidAnswer }
            self = .strings(strings)
        default: throw BackendFormError.invalidAnswer
        }
    }

    var jsonValue: OpenCodeJSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .boolean(let value): return .bool(value)
        case .strings(let values): return .array(values.map(OpenCodeJSONValue.string))
        }
    }

    init(from decoder: Decoder) throws { try self.init(jsonValue: OpenCodeJSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws {
        _ = try Self(jsonValue: jsonValue)
        try jsonValue.encode(to: encoder)
    }
}

typealias BackendFormAnswer = [String: BackendFormValue]
// Missing entry uses a default; .null is an explicit local unset, never a wire answer.
typealias BackendFormDraft = [String: OpenCodeJSONValue]

enum BackendFormState: Equatable, Sendable {
    case pending, answered(BackendFormAnswer), cancelled
}

enum BackendFormError: Error, Equatable {
    case unsupported, invalidField(String), invalidAnswer
}

struct BackendFormContract: Sendable {
    enum Policy { case session, provider }
    let fields: [BackendFormField]

    func isSupported(policy: Policy = .session) -> Bool {
        if policy == .session && fields.isEmpty { return false }
        var earlier: [String: BackendFormField] = [:]
        var keys: Set<String> = []
        for field in fields {
            guard field.supports(policy: policy), keys.insert(field.id).inserted,
                  let conditions = field.conditions else { return false }
            for condition in conditions {
                guard let target = earlier[condition.key], target.canCompare(condition.value) else { return false }
            }
            if field.type != "external" { earlier[field.id] = field }
        }
        return true
    }

    func activeFields(values: BackendFormDraft, policy: Policy = .session) -> [BackendFormField] {
        guard isSupported(policy: policy) else { return [] }
        return resolve(values: values).fields
    }

    func answer(values: BackendFormDraft, policy: Policy = .session) throws -> BackendFormAnswer {
        guard isSupported(policy: policy) else { throw BackendFormError.unsupported }
        let resolved = resolve(values: values)
        var answer: BackendFormAnswer = [:]
        for field in resolved.fields {
            guard let value = resolved.answer[field.id] else {
                if field.required { throw BackendFormError.invalidField(field.title) }
                continue
            }
            guard field.accepts(value) else { throw BackendFormError.invalidField(field.title) }
            answer[field.id] = try BackendFormValue(jsonValue: value)
        }
        return answer
    }

    private func resolve(values: BackendFormDraft) -> (fields: [BackendFormField], answer: BackendFormDraft) {
        var active: [BackendFormField] = []
        var answer: BackendFormDraft = [:]
        // Declaration order prevents hidden values/defaults from activating descendants.
        for field in fields {
            guard field.conditions?.allSatisfy({ $0.matches(answer) }) == true else { continue }
            active.append(field)
            answer[field.id] = field.effectiveValue(draft: values[field.id])
        }
        return (active, answer)
    }
}

struct BackendFormField: Decodable, Equatable, Identifiable, Sendable {
    struct Condition: Equatable, Sendable {
        let key: String
        let op: String
        let value: OpenCodeJSONValue

        init?(_ raw: OpenCodeJSONValue) {
            guard let object = raw.objectValue, Set(object.keys) == ["key", "op", "value"],
                  let key = object["key"]?.v2ConfigurationString,
                  let op = object["op"]?.v2ConfigurationString, ["eq", "neq"].contains(op),
                  let value = object["value"] else { return nil }
            self.key = key
            self.op = op
            self.value = value
        }

        func matches(_ answer: BackendFormDraft) -> Bool {
            guard let actual = answer[key] else { return false }
            let hit: Bool?
            if case .array(let selections) = actual {
                guard value.v2ConfigurationString != nil else { return false }
                hit = selections.contains { $0.v2FormEquals(value) == true }
            } else { hit = actual.v2FormEquals(value) }
            guard let hit else { return false }
            return op == "eq" ? hit : !hit
        }
    }

    let raw: [String: OpenCodeJSONValue]
    init(raw: [String: OpenCodeJSONValue]) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try [String: OpenCodeJSONValue](from: decoder) }

    var id: String { raw["key"]?.v2ConfigurationString ?? "" }
    var type: String { raw["type"]?.v2ConfigurationString ?? "" }
    var title: String { raw["title"]?.v2ConfigurationString ?? id }
    var required: Bool { type == "external" || raw["required"] == .bool(true) }
    var options: [[String: OpenCodeJSONValue]] { raw["options"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
    var allowsCustom: Bool { raw["custom"] == .bool(true) }
    var hasClosedOptions: Bool { raw["options"] != nil && !allowsCustom }
    var conditions: [Condition]? {
        guard let rawConditions = raw["when"] else { return [] }
        guard let values = rawConditions.arrayValue else { return nil }
        let conditions = values.compactMap(Condition.init)
        return conditions.count == values.count ? conditions : nil
    }
    var browserURL: URL? {
        guard let text = raw["url"]?.v2ConfigurationString, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var isSupported: Bool { supports(policy: .provider) }

    func supports(policy: BackendFormContract.Policy) -> Bool {
        guard !id.isEmpty, conditions != nil else { return false }
        var known: Set<String> = ["key", "type", "title", "description", "required", "when", "default"]
        switch type {
        case "string":
            known.formUnion(["minLength", "maxLength", "placeholder", "options", "custom"])
            if policy == .session { known.formUnion(["pattern", "format"]) }
        case "number", "integer": known.formUnion(["minimum", "maximum"])
        case "boolean": break
        case "multiselect": known.formUnion(["options", "custom", "minItems", "maxItems"])
        case "external" where policy == .session:
            known = ["key", "type", "title", "description", "url"]
            guard raw["url"]?.v2ConfigurationString != nil else { return false }
        default: return false
        }
        // Preserve unknown constraints/security hints instead of silently flattening them.
        guard Set(raw.keys).isSubset(of: known) else { return false }
        for key in ["title", "description", "placeholder", "pattern"] where raw[key] != nil {
            guard raw[key]?.v2ConfigurationString != nil else { return false }
        }
        if let format = raw["format"] {
            guard let format = format.v2ConfigurationString, ["email", "uri", "date", "date-time"].contains(format) else { return false }
        }
        for key in ["required", "custom"] where raw[key] != nil {
            guard let value = raw[key], case .bool = value else { return false }
        }
        if policy == .provider, type == "multiselect", allowsCustom { return false }
        if let rawOptions = raw["options"] {
            guard let values = rawOptions.arrayValue else { return false }
            let ids = options.compactMap { $0["value"]?.v2ConfigurationString }
            guard ids.count == values.count,
                  Set(ids.map { Array($0.utf16) }).count == ids.count,
                  options.allSatisfy({ $0["label"]?.v2ConfigurationString != nil }) else { return false }
        }
        if type == "multiselect", raw["options"]?.arrayValue == nil { return false }
        for (minimum, maximum) in [("minimum", "maximum"), ("minLength", "maxLength"), ("minItems", "maxItems")] {
            for key in [minimum, maximum] where raw[key] != nil {
                guard let number = bound(key), number.isFinite else { return false }
                if minimum != "minimum", number < 0 || number.rounded() != number { return false }
            }
            if let lower = bound(minimum), let upper = bound(maximum), lower > upper { return false }
        }
        if let value = raw["default"], !hasExpectedType(value) { return false }
        return true
    }

    func effectiveValue(draft: OpenCodeJSONValue?) -> OpenCodeJSONValue? {
        guard let value = draft ?? raw["default"], value != .null else { return nil }
        if (type == "number" || type == "integer"), let text = value.v2ConfigurationString,
           let number = Double(text) { return .number(number) }
        return value
    }

    func canCompare(_ value: OpenCodeJSONValue) -> Bool {
        if type == "multiselect" {
            return value.v2ConfigurationString != nil && (allowsCustom || options.contains { $0["value"]?.v2FormEquals(value) == true })
        }
        guard hasExpectedType(value) else { return false }
        return !hasClosedOptions || options.contains { $0["value"]?.v2FormEquals(value) == true }
    }

    func accepts(_ value: OpenCodeJSONValue) -> Bool {
        // JS pattern/format checks remain server-authoritative; portable constraints are shared.
        switch (type, value) {
        case ("external", .bool(let acknowledged)): return acknowledged && browserURL != nil
        case ("string", .string(let text)):
            if required && text.isEmpty { return false }
            guard within(Double(text.utf16.count), minimum: "minLength", maximum: "maxLength") else { return false }
            return !hasClosedOptions || options.contains { $0["value"]?.v2FormEquals(value) == true }
        case ("number", .number(let number)), ("integer", .number(let number)):
            return number.isFinite && (type != "integer" || number.rounded() == number)
                && within(number, minimum: "minimum", maximum: "maximum")
        case ("boolean", .bool): return true
        case ("multiselect", .array(let values)):
            return (!required || !values.isEmpty) && within(Double(values.count), minimum: "minItems", maximum: "maxItems") && values.allSatisfy { candidate in
                candidate.v2ConfigurationString != nil && (allowsCustom || options.contains { $0["value"]?.v2FormEquals(candidate) == true })
            }
        default: return false
        }
    }

    private func hasExpectedType(_ value: OpenCodeJSONValue) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool): return true
        case ("number", .number(let number)), ("integer", .number(let number)): return number.isFinite
        case ("multiselect", .array(let values)): return values.allSatisfy { $0.v2ConfigurationString != nil }
        default: return false
        }
    }

    private func bound(_ key: String) -> Double? {
        if let value = raw[key], case .number(let number) = value { return number }
        return nil
    }

    private func within(_ value: Double, minimum: String, maximum: String) -> Bool {
        (bound(minimum).map { value >= $0 } ?? true) && (bound(maximum).map { value <= $0 } ?? true)
    }
}

extension OpenCodeJSONValue {
    func v2FormEquals(_ other: Self) -> Bool? {
        switch (self, other) {
        case (.string(let lhs), .string(let rhs)): return lhs.utf16.elementsEqual(rhs.utf16)
        case (.number(let lhs), .number(let rhs)): return lhs == rhs
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        default: return nil
        }
    }
}
