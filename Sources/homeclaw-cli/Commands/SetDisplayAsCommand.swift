import ArgumentParser
import Foundation

struct SetDisplayAs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-display-as",
        abstract: "Set the Home app's Display As (switch/outlet → light or fan)",
        discussion: """
            Applies only to switch and outlet services, matching the Home app: a switch
            can show as a switch, light, or fan; an outlet as an outlet, light, or fan.
            "default" restores the service's own type. On a multi-gang accessory, pick
            one gang with --service-name, --service-index, or --service-id, or pass
            that service's UUID as the accessory argument.
            """
    )

    @Argument(help: "Accessory name or UUID, or a service UUID")
    var accessory: String

    /// The Home app's Display As choices. Which of switch/outlet is valid depends on
    /// the service, so the app checks that; anything else is a usage error here.
    enum Value: String, ExpressibleByArgument, CaseIterable {
        case light, fan, `switch`, outlet, `default`
    }

    @Argument(help: "What the service displays as")
    var displayAs: Value

    @Option(name: .long, help: "Target services by service type UUID")
    var serviceType: String?

    @Option(name: .long, help: "Target the service with this name or service UUID (e.g. \"Switch 2\")")
    var serviceName: String?

    @Option(name: .long, help: "Target the service with this unique UUID (the per-service id in `get --json`)")
    var serviceID: String?

    @Option(name: .long, help: "Target the service with this channel number (ServiceLabelIndex), e.g. 2 for the second gang")
    var serviceIndex: Int?

    @Option(name: .long, help: "Home name or UUID (defaults to primary home)")
    var home: String?

    @Flag(name: .long, help: "Preview changes without applying")
    var dryRun = false

    @Flag(name: .long, help: "Output raw JSON")
    var json = false

    func validate() throws {
        if let serviceIndex, serviceIndex < 1 {
            throw ValidationError("--service-index is 1-based; got \(serviceIndex)")
        }
    }

    func run() throws {
        if let err = validateInput(accessory, label: "accessory") { throw ValidationError(err) }
        if let serviceName, let err = validateInput(serviceName, label: "service-name") { throw ValidationError(err) }
        if let serviceID, let err = validateInput(serviceID, label: "service-id") { throw ValidationError(err) }

        var args: [String: Any] = [
            "id": accessory,
            "display_as": displayAs.rawValue,
            "dry_run": dryRun,
        ]
        if let home { args["home_id"] = home }
        if let serviceType { args["service_type"] = serviceType }
        if let serviceName { args["service_name"] = serviceName }
        if let serviceID { args["service_id"] = serviceID }
        if let serviceIndex { args["service_index"] = serviceIndex }

        let response = try SocketClient.sendAny(command: "set_display_as", args: args)

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

        let accessoryName = result["accessory"] as? String ?? accessory
        let resolvedServiceName = (result["service"] as? [String: Any])?["name"] as? String ?? "?"
        let old = result["old_display_as"] as? String ?? "?"
        let new = result["new_display_as"] as? String ?? "?"
        if result["dry_run"] as? Bool == true {
            print("DRY RUN — would display '\(resolvedServiceName)' on '\(accessoryName)' as \(new) (currently \(old))")
        } else {
            print("'\(resolvedServiceName)' on '\(accessoryName)' now displays as \(new) (was \(old))")
        }
    }
}
