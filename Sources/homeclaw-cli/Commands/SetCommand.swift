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

    @Option(name: .long, help: "Target services by service type UUID when the characteristic exists on multiple services")
    var serviceType: String?

    @Option(name: .long, help: "Target one service by its name or service UUID (use for multi-gang switches, where every channel shares a service type)")
    var serviceName: String?

    @Option(name: .long, help: "Target one service by its unique UUID (the service_id shown in the ambiguity error and in `get --json`)")
    var serviceID: String?

    @Option(name: .long, help: "Target one service by its channel number (ServiceLabelIndex), e.g. 1 for the first gang")
    var serviceIndex: Int?

    @Flag(name: .long, help: "Validate without writing to the device")
    var dryRun = false

    @Flag(name: .long, help: "Accept the write without reading the value back (skips the check that the device actually changed)")
    var noVerify = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        if let err = validateInput(characteristic, label: "characteristic") { throw ValidationError(err) }
        if let err = validateInput(value, label: "value") { throw ValidationError(err) }
        if let serviceName, let err = validateInput(serviceName, label: "service-name") { throw ValidationError(err) }
        if let serviceID, let err = validateInput(serviceID, label: "service-id") { throw ValidationError(err) }

        var args: [String: String] = [
            "id": accessory,
            "characteristic": characteristic,
            "value": value,
        ]
        if let serviceType { args["service_type"] = serviceType }
        if let serviceName { args["service_name"] = serviceName }
        if let serviceID { args["service_id"] = serviceID }
        if let serviceIndex { args["service_index"] = String(serviceIndex) }
        if dryRun { args["dry_run"] = "true" }
        if noVerify { args["verify"] = "false" }

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
                // Name the service too when it adds information, so a multi-gang write
                // says which channel it hit.
                let written = (data["service"] as? [String: Any])?["name"] as? String
                let serviceLabel = (written == nil || written == name) ? "" : ".\(written ?? "")"
                print("Set \(name)\(serviceLabel).\(characteristic) = \(value)")
                // An unapplied write comes back as a failed response, so reaching here
                // means the write landed or could not be checked. Say which.
                if let reason = data["verification_skipped"] as? String, reason == "read_failed" {
                    print("Note: could not read the value back to confirm the change.")
                }
            } else {
                print("Done.")
            }
        } else {
            print("Done.")
        }
    }
}
