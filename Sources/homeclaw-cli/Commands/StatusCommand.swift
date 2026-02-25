import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show HomeClaw status"
    )

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        let response = try SocketClient.send(command: "status")

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if json {
            printJSON(response.data?.value)
            return
        }

        guard let status = response.data?.value as? [String: Any] else {
            print("Could not parse status.")
            return
        }

        let ready = (status["ready"] as? Bool ?? false) ? "Connected" : "Connecting..."
        let homes = status["homes"] as? Int ?? 0
        let accessories = status["accessories"] as? Int ?? 0
        let version = status["version"] as? String ?? "?"

        print("HomeClaw v\(version)")
        print("  HomeKit:     \(ready)")
        print("  Homes:       \(homes)")
        print("  Accessories: \(accessories)")
        print("  CLI Socket:  \(SocketClient.socketPath)")
    }
}
