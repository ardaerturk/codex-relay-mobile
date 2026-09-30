import Foundation

@main
struct KeychainChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: KeychainChecks write|read|delete unique-test-account") }
        let mode = CommandLine.arguments[1], account = "relay-test-" + CommandLine.arguments[2]
        switch mode {
        case "write":
            try Keychain.save("synthetic-first-value", account: account)
            guard Keychain.read(account: account) == "synthetic-first-value" else { fatalError("Keychain read failed") }
            try Keychain.save("synthetic-updated-value", account: account)
            guard Keychain.read(account: account) == "synthetic-updated-value" else { fatalError("Keychain update failed") }
        case "read":
            guard Keychain.read(account: account) == "synthetic-updated-value" else { fatalError("Credential did not survive process restart") }
        case "delete":
            Keychain.delete(account: account)
            guard Keychain.read(account: account) == nil else { fatalError("Test item was not deleted") }
        default: fatalError("Unknown mode")
        }
        print("PASS native Keychain: \(mode)")
    }
}
