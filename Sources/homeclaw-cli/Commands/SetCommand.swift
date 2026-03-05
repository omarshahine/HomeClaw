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

    @Option(name: .long, help: "Target a specific service by UUID when the characteristic exists on multiple services")
    var serviceType: String?

    func run() throws {
        var args: [String: String] = [
            "id": accessory,
            "characteristic": characteristic,
            "value": value,
        ]
        if let serviceType { args["service_type"] = serviceType }

        let response = try SocketClient.send(
            command: "control",
            args: args
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
