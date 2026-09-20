import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var search = ""
    @State private var selection: String?
    private var filtered: [TaskSummary] {
        store.tasks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.project.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if !store.connected { welcome }
                else {
                    List(selection: $selection) {
                        if filtered.contains(where: \.isPinned) {
                            Section("Pinned") { ForEach(filtered.filter(\.isPinned)) { taskRow($0) } }
                        }
                        Section("Recent tasks") { ForEach(filtered.filter { !$0.isPinned }) { taskRow($0) } }
                        if store.nextCursor != nil && search.isEmpty {
                            Button("Load more tasks") { Task { await store.refreshTasks(more: true) } }
                        }
                        if filtered.isEmpty { Text(search.isEmpty ? "No tasks on this host yet." : "No matching tasks in the loaded history.").foregroundStyle(.secondary) }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search tasks")
                    .refreshable { await store.refreshTasks() }
                }
                connectionFooter
            }
            .navigationTitle("Relay")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Connection settings")
                }
            }
            .onChange(of: selection) { _, id in if let id { Task { await store.select(id) } } }
        } detail: {
            ConversationView()
        }
        .sheet(isPresented: $store.showSettings) { ConnectionView().environmentObject(store) }
    }
    private func taskRow(_ task: TaskSummary) -> some View {
        NavigationLink(value: task.id) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.status == "active" ? "circle.dotted" : "text.bubble")
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(task.project).lineLimit(1)
                        Text("·")
                        Text(Date(timeIntervalSince1970: task.updatedAt), style: .relative).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if task.status == "active" { Circle().fill(.green).frame(width: 6, height: 6).padding(.top, 8) }
            }.padding(.vertical, 8)
        }.listRowSeparator(.hidden)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "terminal").font(.system(size: 42, weight: .light))
            Text("Your workspace.\nWithin reach.").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
            Text("Continue your Codex tasks from your phone. Your code, tools, and Azure connection stay on your VM.")
                .font(.body).foregroundStyle(.secondary).lineSpacing(4)
            Button { store.showSettings = true } label: {
                HStack { Text("Connect your VM").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.right") }
                    .padding(18).background(Color.primary, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color(uiColor: .systemBackground))
            }.buttonStyle(.plain)
            Text("Private connection over Tailscale").font(.caption).foregroundStyle(.secondary)
            Spacer(); Spacer()
        }.padding(28)
    }
    private var connectionFooter: some View {
        Button { store.showSettings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 19))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.host?.name ?? "Your VM").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 5) {
                        Circle().fill(store.connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(store.connection).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.padding(18).background(Color(uiColor: .secondarySystemBackground))
        }.buttonStyle(.plain)
    }
}
