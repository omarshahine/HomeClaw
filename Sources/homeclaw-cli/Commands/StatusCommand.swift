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

        if shouldOutputJSON(json) {
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
            let delivered = webhook["total_delivered"] as? Int ?? 0
            let dropped = webhook["total_dropped"] as? Int ?? 0
            let failures = webhook["consecutive_failures"] as? Int ?? 0
            let lastHTTP = webhook["last_http_status"] as? Int
            let lastSuccess = webhook["last_success"] as? String
            let lastFailure = webhook["last_failure"] as? String

            if enabled {
                switch circuitState {
                case "softOpen":
                    let remaining = webhook["remaining_seconds"] as? Int ?? 0
                    let tripCount = webhook["soft_trip_count"] as? Int ?? 0
                    let minutes = remaining / 60
                    let seconds = remaining % 60
                    print("  Webhook:     \u{26A0}\u{FE0F}  Circuit open \u{2014} paused, auto-resuming in \(minutes)m \(seconds)s")
                    print("               Trip \(tripCount)/3, \(delivered) delivered, \(dropped) dropped")
                    if let status = lastHTTP { print("               Last HTTP status: \(status)") }
                case "hardOpen":
                    print("  Webhook:     \u{274C} Circuit hard-open \u{2014} \(dropped) dropped")
                    print("               Run: homeclaw-cli config --webhook-reset")
                    if let status = lastHTTP { print("               Last HTTP status: \(status)") }
                default:
                    if failures > 0 {
                        print("  Webhook:     \u{2705} Delivering (\(delivered) sent, \(failures) consecutive failures)")
                        if let ts = lastFailure {
                            print("               Last failure: \(ts)")
                        }
                    } else {
                        print("  Webhook:     \u{2705} Delivering (\(delivered) sent, 0 failed)")
                    }
                    if let ts = lastSuccess {
                        print("               Last success: \(ts)")
                    }
                }
                if let ts = lastFailure, circuitState != "closed" {
                    print("               Last failure: \(ts)")
                }
            } else {
                print("  Webhook:     Disabled")
            }
        }
    }
}
