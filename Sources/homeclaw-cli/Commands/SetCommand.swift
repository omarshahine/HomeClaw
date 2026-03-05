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

    @Flag(name: .long, help: "Validate without writing to the device")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        if let err = validateInput(characteristic, label: "characteristic") { throw ValidationError(err) }
        if let err = validateInput(value, label: "value") { throw ValidationError(err) }

        var args: [String: String] = [
            "id": accessory,
            "characteristic": characteristic,
            "value": value,
        ]
        if let serviceType { args["service_type"] = serviceType }
        if dryRun { args["dry_run"] = "true" }

        let response = try SocketClient.send(
            command: "control",
            args: args
        )

        guard response.success else {
            throw ValidationError(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        if let data = response.data?.value as? [String: Any] {
            if data["dry_run"] as? Bool == true {
                let name = data["name"] as? String ?? accessory
                let current = data["current_value"] as? String ?? "?"
                print("Dry run: \(name).\(characteristic) = \(current) -> \(value) (valid)")
            } else if let name = data["name"] as? String {
                print("Set \(name).\(characteristic) = \(value)")
            } else {
                print("Done.")
            }
        } else {
            print("Done.")
        }
    }
}
