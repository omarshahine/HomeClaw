import ArgumentParser
import Foundation

struct Token: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or rotate the MCP bearer token"
    )

    @Flag(name: .long, help: "Generate a new token (invalidates the old one)")
    var rotate = false

    func run() throws {
        var args: [String: String] = [:]
        if rotate { args["rotate"] = "true" }

        let response = try SocketClient.send(command: "token", args: args.isEmpty ? nil : args)

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        guard let data = response.data?.value as? [String: Any],
              let token = data["token"] as? String
        else {
            print("Could not retrieve token.")
            return
        }

        if rotate {
            print("Token rotated successfully.")
        }
        print(token)
    }
}
