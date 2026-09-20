import Foundation

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String { if case .string(let s) = self { return s }; if case .number(let n) = self { return String(Int(n)) }; return "" }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? ""
    }
}

struct TaskSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    let provider: String
    let status: String
    let updatedAt: Double
    let isPinned: Bool
    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

struct TaskPage: Decodable { let data: [TaskSummary]; let nextCursor: String? }
struct HostHealth: Decodable { let name: String; let bridgeVersion: String; let desktopConnected: Bool; let capabilities: [String]; let newTaskSupported: Bool }
struct TimelineItem: Codable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let title: String
    let status: String
    let phase: String
    var isMessage: Bool { kind == "userMessage" || kind == "agentMessage" }
}
struct Conversation: Codable, Identifiable {
    let id: String
    let title: String
    let cwd: String
    let model: String
    let effort: String
    let provider: String
    let status: String
    let revision: Int
    let ownerAvailable: Bool
    let activeTurnId: String?
    let messages: [TimelineItem]
    let requests: [JSONValue]
    let diff: String?
    let permissions: String
    let historyComplete: Bool
    var isRunning: Bool { status == "active" || activeTurnId != nil }
}
struct ConversationPatch: Decodable {
    let metadata: JSONValue
    let upserts: [TimelineItem]
    let order: [String]
    func applying(to existing: Conversation) throws -> Conversation {
        var items = Dictionary(existing.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for item in upserts { items[item.id] = item }
        guard order.allSatisfy({ items[$0] != nil }), case .object(var object) = metadata else {
            throw RelayError.message("Conversation update missed data. Reconnecting…")
        }
        let data = try JSONEncoder().encode(order.compactMap { items[$0] })
        object["messages"] = try JSONDecoder().decode(JSONValue.self, from: data)
        return try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(JSONValue.object(object)))
    }
}
struct StreamEvent: Decodable { let type: String; let conversation: Conversation?; let patch: ConversationPatch? }
struct CommandReceipt: Decodable { let status: String; let result: JSONValue? }
struct PendingPrompt: Codable { let id: String; let threadID: String; let text: String; let address: String }

enum RelayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
