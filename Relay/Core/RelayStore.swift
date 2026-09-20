import Foundation
import SwiftUI

@MainActor
final class RelayStore: ObservableObject {
    @Published var tasks: [TaskSummary] = []
    @Published var conversation: Conversation?
    @Published var selectedID: String?
    @Published var host: HostHealth?
    @Published var connection = "Not connected"
    @Published var error: String?
    @Published var loading = false
    @Published var sending = false
    @Published var draft = ""
    @Published var pending: PendingPrompt?
    @Published var showSettings = false
    @Published var nextCursor: String?
    @Published var connected = false
    @Published var live = false
    @Published var address = UserDefaults.standard.string(forKey: "relay.address") ?? ""
    private var api: RelayAPI?
    private var updates: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var drafts: [String: String] = [:]
    private let pendingAccount = "pending-prompt"

    init() {
        if let raw = Keychain.read(account: pendingAccount), let data = raw.data(using: .utf8) {
            pending = try? JSONDecoder().decode(PendingPrompt.self, from: data)
        }
    }
    func restore() async {
        guard let token = Keychain.read(account: address) else { return }
        await connect(address: address, token: token, save: false)
    }
    func connect(address: String, token: String, save: Bool = true) async {
        guard !loading else { return }
        stopUpdates(); api = nil; connected = false
        loading = true; defer { loading = false }
        do {
            let client = try RelayAPI(address: address, token: token)
            let health: HostHealth = try await client.get("v1/health")
            guard health.desktopConnected else { throw RelayError.message("The bridge is reachable, but Codex desktop is offline on the VM.") }
            if save { try Keychain.save(token, account: address); UserDefaults.standard.set(address, forKey: "relay.address") }
            stopUpdates(); api = client; self.address = address; host = health
            connected = true; connection = "Connected"; error = nil; showSettings = false
            await refreshTasks()
            if let selectedID { await select(selectedID) }
        } catch { self.error = error.localizedDescription; connection = "Connection failed"; connected = false }
    }
    func refreshTasks(more: Bool = false) async {
        guard let api else { return }
        do {
            let query = more ? [URLQueryItem(name: "cursor", value: nextCursor)] : []
            let page: TaskPage = try await api.get("v1/threads", query: query)
            if more {
                let ids = Set(tasks.map(\.id)); tasks += page.data.filter { !ids.contains($0.id) }
            } else { tasks = page.data }
            nextCursor = page.nextCursor
        } catch { self.error = error.localizedDescription }
    }
    func select(_ id: String) async {
        if let selectedID { drafts[selectedID] = draft }
        stopUpdates(); selectedID = id; conversation = nil
        draft = drafts[id] ?? (pending?.threadID == id ? pending?.text ?? "" : "")
        guard let api else { return }
        loading = true; error = nil
        do {
            let value: Conversation = try await api.get("v1/threads/\(id)", query: [URLQueryItem(name: "refresh", value: "true")])
            guard selectedID == id else { return }
            conversation = value; loading = false; startUpdates(id)
        } catch {
            guard selectedID == id else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    private func startUpdates(_ id: String) {
        updates = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled && self.selectedID == id {
                guard let api = self.api else { return }
                let ws = api.socket(thread: id); self.socket = ws; ws.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
                        guard self.selectedID == id, !Task.isCancelled else { return }
                        let value: Conversation?
                        if let full = event.conversation { value = full }
                        else if let patch = event.patch, let existing = self.conversation { value = try patch.applying(to: existing) }
                        else { throw RelayError.message("Incomplete conversation update") }
                        if let value, value.id == id {
                            self.conversation = value
                            self.live = value.ownerAvailable
                            self.connection = self.live ? "Live" : "Desktop unavailable"
                            failures = 0
                            if !self.live { throw RelayError.message("Desktop owner unavailable") }
                        }
                    }
                } catch {
                    ws.cancel(with: .goingAway, reason: nil)
                    if Task.isCancelled { return }
                    self.live = false; self.connection = "Reconnecting…"
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5))))))
                    if Task.isCancelled { return }
                    do {
                        let value: Conversation = try await api.get("v1/threads/\(id)", query: [URLQueryItem(name: "refresh", value: "true")])
                        guard self.selectedID == id else { return }
                        self.conversation = value
                    } catch { self.connection = "VM unavailable · retrying" }
                }
            }
        }
    }
    func stopUpdates() {
        updates?.cancel(); updates = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; live = false
    }
    func foreground() async {
        if api == nil { await restore() }
        else if let selectedID { await select(selectedID) }
        else { await refreshTasks() }
    }
    func send() async {
        guard let api, let id = selectedID, pending == nil, !sending, live else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let attempt = PendingPrompt(id: UUID().uuidString, threadID: id, text: text, address: address)
        sending = true; defer { sending = false }
        do {
            let encoded = try JSONEncoder().encode(attempt)
            try Keychain.save(String(decoding: encoded, as: UTF8.self), account: pendingAccount)
            pending = attempt
            let receipt = try await api.command(thread: id, body: ["id":.string(attempt.id), "operation":.string("send"), "text":.string(text)])
            if receipt.status == "accepted" {
                clearPending(); if selectedID == id { draft = "" }; drafts[id] = ""
            } else { error = "Delivery is uncertain. Review this conversation before composing another prompt." }
        } catch { self.error = "Delivery could not be confirmed. Your prompt is preserved. Review the conversation before trying again. \(error.localizedDescription)" }
    }
    func checkDelivery() async {
        guard let api, let p = pending else { return }
        guard p.address == address else { error = "Reconnect to \(p.address) to check this prompt’s delivery."; return }
        do {
            let result: CommandReceipt = try await api.get("v1/delivery/\(p.id)")
            if result.status == "accepted" { clearPending(); if selectedID == p.threadID { draft = "" }; drafts[p.threadID] = ""; error = nil }
            else { error = "Delivery status: \(result.status). Check the conversation, then dismiss the pending prompt when you are ready." }
        } catch { self.error = error.localizedDescription }
    }
    func clearPending() { pending = nil; Keychain.delete(account: pendingAccount) }
    func command(_ operation: String, fields: [String: JSONValue] = [:]) async {
        guard let api, let id = selectedID, live, !sending else { return }
        sending = true; defer { sending = false }
        var body = fields; body["id"] = .string(UUID().uuidString); body["operation"] = .string(operation)
        do {
            let result = try await api.command(thread: id, body: body)
            if result.status != "accepted" { error = "The action could not be confirmed. Refresh before trying again." }
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        stopUpdates(); Keychain.delete(account: address); api = nil
        connected = false; connection = "Not connected"; host = nil
        tasks = []; conversation = nil; selectedID = nil; draft = ""; drafts = [:]
    }
}
