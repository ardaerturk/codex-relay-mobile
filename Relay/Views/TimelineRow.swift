import SwiftUI

struct TimelineRow: View {
    let item: TimelineItem
    @State private var expanded = false
    var body: some View {
        if item.kind == "userMessage" {
            HStack { Spacer(minLength: 32)
                Text(item.text).font(.system(size: 16)).textSelection(.enabled).lineSpacing(4)
                    .padding(.horizontal, 17).padding(.vertical, 13)
                    .background(Color.relaySecondaryBackground, in: RoundedRectangle(cornerRadius: 20))
            }
        } else if item.kind == "agentMessage" {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownContent(text: item.text)
                if item.phase == "final" {
                    Button { Clipboard.copy(item.text) } label: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
                        .accessibilityLabel("Copy response")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if item.kind != "reasoning" || !item.text.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.horizontal) {
                    Text(item.text.isEmpty ? item.status.capitalized : item.text)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 16)
                    Text(item.title.isEmpty ? item.kind : item.title).lineLimit(2)
                    Spacer(minLength: 0)
                    if item.status == "inProgress" { ProgressView().controlSize(.mini) }
                    else if item.status == "failed" { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            }.tint(.secondary)
        }
    }
    private var icon: String {
        switch item.kind {
        case "commandExecution": return "terminal"
        case "fileChange": return "doc.text"
        case "reasoning": return "sparkle"
        case "mcpToolCall": return "wrench.and.screwdriver"
        default: return "circle.dotted"
        }
    }
}

struct MarkdownContent: View {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
                    let language = lines.first.map(String.init) ?? ""
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "Code" : language).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button { Clipboard.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption2) }
                        }.padding(12)
                        Divider()
                        ScrollView(.horizontal) { Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12) }
                    }.background(Color.relaySecondaryBackground, in: RoundedRectangle(cornerRadius: 12))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(.init(part.trimmingCharacters(in: .newlines))).font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                }
            }
        }
    }
}
