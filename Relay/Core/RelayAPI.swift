import Foundation

final class RelayAPI {
    let base: URL
    private let token: String
    private let session: URLSession
    init(address: String, token: String) throws {
        guard let u = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "https", let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else {
            throw RelayError.message("Use the HTTPS address of your bridge, without a path, username, or query.")
        }
        guard token.count >= 40 else { throw RelayError.message("Paste the complete pairing credential from your VM.") }
        base = u; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await perform(request(path: path, query: query))
    }
    func command(thread: String, body: [String: JSONValue]) async throws -> CommandReceipt {
        var r = request(path: "v1/threads/\(thread)/commands")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return try await perform(r)
    }
    private func perform<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw RelayError.message("No response from the VM.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RelayError.message("Pairing credential was rejected. Check your connection settings.") }
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)
            let message = body?["error"].string
            throw RelayError.message(message?.isEmpty == false ? message! : "The VM returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func socket(thread: String) -> URLSessionWebSocketTask {
        var r = request(path: "v1/threads/\(thread)/stream")
        var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        c.scheme = "wss"; r.url = c.url
        let task = session.webSocketTask(with: r)
        task.maximumMessageSize = 64 * 1024 * 1024
        return task
    }
}
