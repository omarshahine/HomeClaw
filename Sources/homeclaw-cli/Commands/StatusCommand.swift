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

        // Webhook circuit breaker status
        if let webhook = status["webhook"] as? [String: Any] {
            let enabled = webhook["enabled"] as? Bool ?? false
            let circuitState = webhook["circuit_state"] as? String ?? "closed"

            if enabled {
                switch circuitState {
                case "softOpen":
                    let remaining = webhook["remaining_seconds"] as? Int ?? 0
                    let tripCount = webhook["soft_trip_count"] as? Int ?? 0
                    let dropped = webhook["total_dropped"] as? Int ?? 0
                    let minutes = remaining / 60
                    let seconds = remaining % 60
                    print("  Webhook:     \u{26A0} Paused (auto-resuming in \(minutes)m \(seconds)s)")
                    print("               Trip \(tripCount)/3, \(dropped) dropped")
                case "hardOpen":
                    let dropped = webhook["total_dropped"] as? Int ?? 0
                    print("  Webhook:     \u{274C} Disabled (\(dropped) dropped)")
                    print("               Toggle webhook off\u{2192}on to re-enable")
                default:
                    print("  Webhook:     \u{2705} Active")
                }
            } else {
                print("  Webhook:     Disabled")
            }
        }
    }
}
