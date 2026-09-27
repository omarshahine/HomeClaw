import ArgumentParser
import Foundation

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a HomeKit accessory, or one service (gang) of a multi-service accessory",
        discussion: """
            Without a service selector, renames the accessory and its primary tile.
            To rename one gang of a multi-gang accessory (e.g. the "Switch 2" tile of a
            dual relay), pick it with --service-name, --service-index, or --service-id,
            or pass that service's UUID (the per-service `id` in `get --json`) as the
            accessory argument.
            """
    )

    @Argument(help: "Accessory name or UUID, or a service UUID")
    var accessory: String

    @Argument(help: "New name for the accessory or service")
    var newName: String

    @Option(name: .long, help: "Rename only the services with this service type UUID")
    var serviceType: String?

    @Option(name: .long, help: "Rename only the service with this name or service UUID (e.g. \"Switch 2\")")
    var serviceName: String?

    @Option(name: .long, help: "Rename only the service with this unique UUID (the per-service id in `get --json`)")
    var serviceID: String?

    @Option(name: .long, help: "Rename only the service with this channel number (ServiceLabelIndex), e.g. 2 for the second gang")
    var serviceIndex: Int?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        if let err = validateInput(newName, label: "new name") { throw ValidationError(err) }
        if let serviceName, let err = validateInput(serviceName, label: "service-name") { throw ValidationError(err) }
        if let serviceID, let err = validateInput(serviceID, label: "service-id") { throw ValidationError(err) }

        var args: [String: Any] = [
            "id": accessory,
            "new_name": newName,
            "dry_run": dryRun,
        ]
        if let home { args["home_id"] = home }
        if let serviceType { args["service_type"] = serviceType }
        if let serviceName { args["service_name"] = serviceName }
        if let serviceID { args["service_id"] = serviceID }
        if let serviceIndex { args["service_index"] = serviceIndex }

        let response = try SocketClient.sendAny(command: "rename", args: args)

        guard response.success else {
            throw CommandFailure(response.error ?? "Unknown error")
        }

        if shouldOutputJSON(json) {
            printJSON(response.data?.value)
            return
        }

        guard let result = response.data?.value as? [String: Any] else {
            print("Done.")
            return
        }

        let oldName = result["old_name"] as? String ?? "?"
        let renamedTo = result["new_name"] as? String ?? "?"
        let isDryRun = result["dry_run"] as? Bool ?? false

        // Service-level renames also name the accessory the service belongs to.
        let on = (result["accessory"] as? String).map { " on '\($0)'" } ?? ""
        if isDryRun {
            print("DRY RUN — would rename '\(oldName)'\(on) → '\(renamedTo)'")
        } else {
            print("Renamed '\(oldName)'\(on) → '\(renamedTo)'")
        }
    }
}
