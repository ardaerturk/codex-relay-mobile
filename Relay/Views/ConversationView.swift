import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var store: RelayStore
    @State private var showDetails = false
    @State private var showDiff = false
    @State private var followBottom = true
    @State private var dismissPending = false
    @FocusState private var composing: Bool
    var body: some View {
        VStack(spacing: 0) {
            if let c = store.conversation {
                if !store.live { connectionBanner }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 25) {
                            if !c.historyComplete {
                                Button("Load earlier messages") { Task { await store.command("loadHistory") } }
                                    .font(.caption).frame(maxWidth: .infinity)
                            }
                            ForEach(c.messages) { item in TimelineRow(item: item) }
                            ForEach(Array(c.requests.enumerated()), id: \.offset) { _, request in
                                ApprovalView(request: request).environmentObject(store)
                            }
                            if c.isRunning {
                                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Working on your VM…").font(.subheadline).foregroundStyle(.secondary) }
                                    .accessibilityLabel("Codex is working on your VM")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { followBottom = true }.onDisappear { followBottom = false }
                        }.padding(.horizontal, 20).padding(.vertical, 22).frame(maxWidth: 820)
                    }
                    .relayDismissKeyboard()
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: c.revision) { _, _ in if followBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .overlay(alignment: .bottomTrailing) {
                        if !followBottom {
                            Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                                Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle())
                            }.padding(14).accessibilityLabel("Jump to latest message")
                        }
                    }
                }
                if store.pending != nil { pendingBanner }
                if let error = store.error { errorBanner(error) }
                composer(c)
            } else if store.loading {
                Spacer(); ProgressView("Opening your task…"); Spacer()
            } else if let error = store.error, store.selectedID != nil {
                ContentUnavailableView {
                    Label("Task unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try again") { if let id = store.selectedID { Task { await store.select(id) } } }
                }
            } else {
                ContentUnavailableView("Pick up where you left off", systemImage: "terminal", description: Text("Choose a task from your VM to see its conversation and continue working."))
            }
        }
        .background(Color.relayBackground)
        .navigationTitle(store.conversation?.title ?? "Workspace")
        .relayInlineTitle()
        .toolbar {
            if store.conversation != nil {
                ToolbarItem(placement: .relayTrailing) {
                    Menu {
                        Button("Task details", systemImage: "info.circle") { showDetails = true }
                        if store.conversation?.diff != nil { Button("View changes", systemImage: "chevron.left.forwardslash.chevron.right") { showDiff = true } }
                        Button("Refresh conversation", systemImage: "arrow.clockwise") { if let id = store.selectedID { Task { await store.select(id) } } }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Task options")
                }
            }
        }
        .sheet(isPresented: $showDetails) { details }
        .sheet(isPresented: $showDiff) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) { Text(store.conversation?.diff ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                    .navigationTitle("Changes").relayInlineTitle()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiff = false } } }
            }
        }
        .confirmationDialog("Dismiss the pending prompt?", isPresented: $dismissPending, titleVisibility: .visible) {
            Button("I reviewed the conversation", role: .destructive) { store.clearPending(); store.error = nil }
        } message: { Text("This unlocks the composer. A prompt with uncertain delivery may already have run on the VM.") }
    }
    private var connectionBanner: some View {
        HStack { Image(systemName: "wifi.exclamationmark"); Text(store.connection); Spacer() }
            .font(.caption).padding(12).background(Color.orange.opacity(0.12))
    }
    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt delivery needs checking").font(.caption.weight(.semibold))
            HStack {
                Button("Check delivery") { Task { await store.checkDelivery() } }
                Spacer()
                Button("Dismiss…") { dismissPending = true }
            }.font(.caption)
        }.padding(12).background(Color.orange.opacity(0.12))
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top) {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { store.error = nil } label: { Image(systemName: "xmark").font(.caption) }.accessibilityLabel("Dismiss error")
        }.padding(12)
    }
    private func composer(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(c.isRunning ? "Add a follow-up…" : "Ask Codex to do anything…", text: $store.draft, axis: .vertical)
                .lineLimit(1...7).font(.body).focused($composing)
                .accessibilityLabel("Message to Codex on your VM")
            HStack(alignment: .center) {
                Button { showDetails = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer")
                        Text(c.model.replacingOccurrences(of: "gpt-", with: "")).lineLimit(1)
                        if !c.effort.isEmpty { Text(c.effort.capitalized).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain)
                Spacer(minLength: 8)
                if c.isRunning, let turn = c.activeTurnId {
                    Button { Task { await store.command("stop", fields: ["expectedTurnId": .string(turn)]) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 36, height: 36)
                            .background(Color.relayFill, in: Circle())
                    }.disabled(!store.live || store.sending).accessibilityLabel("Stop current turn")
                }
                Button { Task { await store.send() } } label: {
                    Group {
                        if store.sending { ProgressView().tint(Color.relayBackground) }
                        else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)) }
                    }.frame(width: 36, height: 36).background(Color.primary, in: Circle()).foregroundStyle(Color.relayBackground)
                }.disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.live || store.sending || store.pending != nil)
                    .opacity(store.draft.isEmpty || !store.live || store.pending != nil ? 0.35 : 1)
                    .accessibilityLabel(c.isRunning ? "Send follow-up" : "Send prompt")
            }
        }
        .padding(16).background(Color.relaySecondaryBackground, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
    }
    private var details: some View {
        NavigationStack {
            Form {
                if let c = store.conversation {
                    Section("Execution") {
                        LabeledContent("Host", value: store.host?.name ?? "Your VM")
                        LabeledContent("Provider", value: c.provider)
                        LabeledContent("Model", value: c.model)
                        LabeledContent("Reasoning", value: c.effort.capitalized)
                        LabeledContent("Permissions", value: c.permissions)
                    }
                    Section("Workspace") { Text(c.cwd).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Section { Text("This task uses the model and permissions selected in Codex on your VM. Change those settings on desktop for this version.").font(.footnote).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Task details").relayInlineTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
        }.relayDetailsPresentation()
    }
}
