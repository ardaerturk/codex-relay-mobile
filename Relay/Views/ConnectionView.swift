import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var address = ""
    @State private var showToken = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 30, weight: .light)).padding(.bottom, 4)
                        Text("Connect to your workspace").font(.title2.weight(.semibold))
                        Text("Turn on Tailscale on your iPhone, then enter the bridge address and pairing credential from your VM.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section("Your VM") {
                    TextField("https://your-vm.ts.net:8443", text: $address)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Bridge HTTPS address")
                    HStack {
                        Group {
                            if showToken { TextField("Pairing credential", text: $token) }
                            else { SecureField("Pairing credential", text: $token) }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                            .accessibilityLabel(showToken ? "Hide credential" : "Show credential")
                    }
                }
                Section {
                    Button {
                        Task { await store.connect(address: address.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    } label: {
                        HStack {
                            Text(store.loading ? "Connecting…" : "Connect").fontWeight(.semibold)
                            Spacer()
                            if store.loading { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(store.loading || token.isEmpty || address.isEmpty)
                } footer: {
                    Text("Your Azure key stays on the VM. The pairing credential is stored in this iPhone’s Keychain and is not synced to iCloud.")
                }
                if let error = store.error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
                if store.connected {
                    Section("Connected host") {
                        LabeledContent("Machine", value: store.host?.name ?? "Your VM")
                        LabeledContent("Bridge", value: store.host?.bridgeVersion ?? "")
                        Button("Forget this connection", role: .destructive) { store.disconnect(); dismiss() }
                    }
                }
                Section {
                    Text("Relay is a private companion for Codex. This first build continues tasks already open on your VM. New tasks, model changes, attachments, and voice remain on desktop.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { address = store.address; token = Keychain.read(account: store.address) ?? "" }
        }
    }
}
