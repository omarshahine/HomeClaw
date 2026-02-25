import ArgumentParser
import Foundation

struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a characteristic on an accessory"
    )

    @Argument(help: "Accessory name or UUID")
    var accessory: String

    @Argument(help: "Characteristic name (e.g., power, brightness, target_temperature)")
    var characteristic: String

    @Argument(help: "Value to set (e.g., true, 75, locked)")
    var value: String

    func run() throws {
        let response = try SocketClient.send(
            command: "control",
            args: [
                "id": accessory,
                "characteristic": characteristic,
                "value": value,
            ]
        )

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if let data = response.data?.value as? [String: Any],
           let name = data["name"] as? String
        {
            print("Set \(name).\(characteristic) = \(value)")
        } else {
            print("Done.")
        }
    }
}
