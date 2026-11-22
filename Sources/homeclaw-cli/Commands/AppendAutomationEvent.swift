import ArgumentParser
import Foundation

/// Append-only event edit. Its default is a preview, even though the older
/// automation edit/create commands have different default mutation semantics.
struct AppendAutomationEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append-event", abstract: "Preview or append one characteristic event to an existing automation",
        discussion: """
        Events are OR alternatives evaluated against the automation's unchanged predicate.
        HomeKit can regenerate event IDs and reorder the alternatives.\n        Preview first, then pass --apply --fingerprint with the preview fingerprint.
        Only finite boolean/numeric values are supported. Retargeting is not supported.
        HomeKit has no compare-and-swap: another client can race the write. A failed or
        unverified result must be inspected before retrying; no automatic rollback occurs.
        """)
    @Argument(help: "Automation name or UUID") var id: String
    @Option(name: .long, help: "Accessory name or UUID") var accessory: String
    @Option(name: .long, help: "Characteristic name, for example motion_detected") var characteristic: String
    @Option(name: .customLong("trigger-value"), help: "Explicit boolean/numeric value; never defaults to any change") var triggerValue: String
    @Option(name: .customLong("service-name")) var serviceName: String?
    @Option(name: .customLong("service-id")) var serviceID: String?
    @Option(name: .customLong("service-index")) var serviceIndex: Int?
    @Option(name: .long) var home: String?
    @Flag(name: .long, help: "Apply the previewed append operation") var apply = false
    @Option(name: .long, help: "Fingerprint from a fresh preview in this app session") var fingerprint: String?
    @Flag(name: .long) var json = false

    func validate() throws {
        for (name, text) in [("id", id), ("accessory", accessory), ("characteristic", characteristic), ("trigger-value", triggerValue)] {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("\(name) must be non-empty") }
        }
        for text in [serviceName, serviceID, home, fingerprint].compactMap({ $0 }) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("Optional selectors/fingerprint must be non-empty") }
        }
        if let serviceIndex, serviceIndex < 1 { throw ValidationError("service-index must be positive") }
        if apply && fingerprint == nil { throw ValidationError("--apply requires --fingerprint from a fresh preview") }
    }

    func socketArgs() -> [String: Any] {
        var args: [String: Any] = ["id": id, "accessory_id": accessory, "characteristic": characteristic, "trigger_value": triggerValue, "apply": apply]
        args["home_id"] = home; args["service_name"] = serviceName; args["service_id"] = serviceID
        args["service_index"] = serviceIndex; args["fingerprint"] = fingerprint
        return args
    }

    func run() throws {
        let response = try SocketClient.sendAny(command: "append_automation_event", args: socketArgs())
        guard response.success else { throw CommandFailure(response.error ?? "Unknown error") }
        // Always show status/fingerprint/warnings, including unverified outcomes.
        printJSON(response.data?.value)
        if let result = response.data?.value as? [String: Any], let status = result["status"] as? String,
           ["failed", "unverified"].contains(status) { throw ExitCode.failure }
    }
}
