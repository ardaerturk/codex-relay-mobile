import Foundation

@main
struct ProtocolChecks {
    static func main() async throws {
        let json = """
        {"id":"thread-test","title":"Test","cwd":"/work","model":"host-model","effort":"medium","provider":"azure","status":"idle","revision":1,"ownerAvailable":true,"activeTurnId":null,"messages":[{"id":"a","kind":"agentMessage","text":"First","title":"","status":"","phase":"final"}],"requests":[],"diff":null,"permissions":"readOnly","historyComplete":true}
        """
        let c = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let patch = ConversationPatch(metadata: metadata, upserts: [TimelineItem(id:"a",kind:"agentMessage",text:"Updated",title:"",status:"",phase:"final")],order:["a"])
        let updated = try patch.applying(to: c)
        precondition(updated.messages.first?.text == "Updated")
        let missing = ConversationPatch(metadata: metadata, upserts: [],order:["missing"])
        do { _ = try missing.applying(to: c); fatalError("Missing patch item accepted") } catch {}
        for url in ["http://host", "https://user:pass@host", "https://host/?token=x", "https://host/path"] {
            do { _ = try RelayAPI(address:url,token:String(repeating:"x",count:48));fatalError("Unsafe endpoint accepted") } catch {}
        }
        _ = try RelayAPI(address:"https://vm.example.ts.net:8443",token:String(repeating:"x",count:48))
        print("PASS: Swift decoding, patch reconciliation, missing-item detection, HTTPS URL validation")
        guard CommandLine.arguments.count == 3 else { return }
        let token = try String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let api = try RelayAPI(address:CommandLine.arguments[1],token:token)
        let h: HostHealth = try await api.get("v1/health")
        precondition(h.desktopConnected)
        let page: TaskPage = try await api.get("v1/threads")
        guard let first = page.data.first else { fatalError("No tasks") }
        let live: Conversation = try await api.get("v1/threads/\(first.id)")
        precondition(live.ownerAvailable && live.id == first.id)
        print("PASS: Swift URLSession HTTPS read",live.messages.count,"real timeline items")
        let ws=api.socket(thread:first.id);ws.resume()
        defer { ws.cancel(with:.goingAway,reason:nil) }
        let value=try await ws.receive()
        let data: Data
        switch value { case .data(let d): data=d; case .string(let s): data=Data(s.utf8); @unknown default:fatalError("Unknown WebSocket frame") }
        let event=try JSONDecoder().decode(StreamEvent.self,from:data)
        precondition(event.conversation?.id==first.id)
        print("PASS: Swift URLSession WSS received real desktop snapshot")
        let receipt = try await api.command(thread:first.id,body:["id":.string(UUID().uuidString),"operation":.string("loadHistory")])
        precondition(receipt.status=="accepted")
        let update=try await ws.receive()
        let nextData: Data
        switch update { case .data(let d): nextData=d; case .string(let s): nextData=Data(s.utf8); @unknown default:fatalError("Unknown update") }
        let next=try JSONDecoder().decode(StreamEvent.self,from:nextData)
        guard let received=next.patch,let snapshot=event.conversation else { fatalError("Expected incremental patch after history request") }
        let reconciled=try received.applying(to:snapshot)
        precondition(reconciled.id==first.id)
        print("PASS: read-only desktop history command and incremental Swift stream reconciliation")
    }
}
