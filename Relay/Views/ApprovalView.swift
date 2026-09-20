import SwiftUI

struct ApprovalView: View {
    @EnvironmentObject private var store: RelayStore
    let request: JSONValue
    @State private var answers: [String: String] = [:]
    private var method: String { request["method"].string }
    private var params: JSONValue { request["params"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your input is needed", systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            if method == "item/tool/requestUserInput" {
                ForEach(Array(params["questions"].array.enumerated()), id: \.offset) { _, q in
                    let id = q["id"].string
                    Text(q["question"].string).font(.subheadline)
                    ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                        Button { answers[id] = option["label"].string } label: {
                            HStack(alignment: .top) {
                                Image(systemName: answers[id] == option["label"].string ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option["label"].string)
                                    if !option["description"].string.isEmpty { Text(option["description"].string).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.font(.subheadline)
                        }.buttonStyle(.plain)
                    }
                    TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.subheadline)
                }
                Button("Send answers") {
                    let values = answers.mapValues { JSONValue.object(["answers": .array([.string($0)])]) }
                    Task { await store.command("answer", fields: ["requestId": request["id"], "answers": .object(values)]) }
                }.buttonStyle(.borderedProminent)
                    .disabled(params["questions"].array.contains { (answers[$0["id"].string] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || !store.live || store.sending)
            } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                if !params["reason"].string.isEmpty { Text(params["reason"].string).font(.subheadline) }
                if !params["command"].string.isEmpty {
                    Text(params["command"].string).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                DisclosureGroup("Request details") { Text(params.pretty).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
                HStack {
                    decision("Decline", value: "decline")
                    Spacer()
                    decision("Allow once", value: "accept")
                }
            } else {
                Text("This request needs the desktop app. Open Codex on your VM to respond.").font(.subheadline).foregroundStyle(.secondary)
                DisclosureGroup("Request details") { Text(params.pretty).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
            }
        }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.25)))
    }
    private func decision(_ title: String, value: String) -> some View {
        let available = params["availableDecisions"].array
        return Button(title) {
            Task { await store.command(method == "item/commandExecution/requestApproval" ? "approveCommand" : "approveFile", fields: ["requestId": request["id"], "decision": .string(value)]) }
        }.buttonStyle(.bordered).disabled(!store.live || store.sending || (!available.isEmpty && !available.contains(.string(value))))
    }
}
