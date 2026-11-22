import Foundation
import Testing
@testable import homeclaw_cli

@Suite("AppendAutomationEvent CLI")
struct AppendAutomationEventTests {
    let base = ["Rule", "--accessory", "Sensor", "--characteristic", "motion_detected", "--trigger-value", "true"]
    @Test func previewsByDefault() throws {
        let cmd = try AppendAutomationEvent.parse(base)
        try cmd.validate()
        #expect(cmd.socketArgs()["apply"] as? Bool == false)
        #expect(cmd.socketArgs()["trigger_value"] as? String == "true")
    }
    @Test func applyRequiresFingerprint() throws {
        #expect(throws: (any Error).self) {
            let cmd = try AppendAutomationEvent.parse(base + ["--apply"])
            try cmd.validate()
        }
    }
    @Test func forwardsExactProposalAndFingerprint() throws {
        let cmd = try AppendAutomationEvent.parse(base + ["--apply", "--fingerprint", "fresh", "--service-id", "uuid", "--service-index", "2", "--home", "home"])
        try cmd.validate()
        let args = cmd.socketArgs()
        #expect(args["apply"] as? Bool == true)
        #expect(args["fingerprint"] as? String == "fresh")
        #expect(args["service_id"] as? String == "uuid")
        #expect(args["service_index"] as? Int == 2)
        #expect(args["home_id"] as? String == "home")
    }
    @Test func explicitValueAndNonemptySelectorsRequired() throws {
        for extra in [["--trigger-value", ""], ["--service-name", " "], ["--fingerprint", ""], ["--service-index", "0"]] {
            #expect(throws: (any Error).self) {
                let cmd = try AppendAutomationEvent.parse(base + extra)
                try cmd.validate()
            }
        }
        #expect(throws: (any Error).self) { try AppendAutomationEvent.parse(["Rule", "--accessory", "Sensor", "--characteristic", "motion_detected"]) }
    }
}

@Suite("RetargetAutomationEvent CLI")
struct RetargetAutomationEventTests {
    let base = ["Rule", "--accessory", "Sensor", "--characteristic", "motion_detected", "--trigger-value", "true"]
    @Test func requiresExactUUIDAndPreviewsByDefault() throws {
        #expect(throws: (any Error).self) { try RetargetAutomationEvent.parse(base) }
        #expect(throws: (any Error).self) {
            try RetargetAutomationEvent.parse(base + ["--event-id", "first"]).validate()
        }
        let id = UUID().uuidString
        let command = try RetargetAutomationEvent.parse(base + ["--event-id", id])
        try command.validate()
        #expect(command.socketArgs()["event_id"] as? String == id)
        #expect(command.socketArgs()["apply"] as? Bool == false)
    }

    @Test func applyRequiresProposalFingerprintAndKeepsServiceSelector() throws {
        let args = base + ["--event-id", UUID().uuidString, "--apply", "--service-index", "2"]
        #expect(throws: (any Error).self) { try RetargetAutomationEvent.parse(args).validate() }
        let command = try RetargetAutomationEvent.parse(args + ["--fingerprint", "precise"])
        try command.validate()
        #expect(command.socketArgs()["apply"] as? Bool == true)
        #expect(command.socketArgs()["fingerprint"] as? String == "precise")
        #expect(command.socketArgs()["service_index"] as? Int == 2)
    }
}
