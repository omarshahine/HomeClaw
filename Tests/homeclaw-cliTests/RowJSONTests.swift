import ArgumentParser
import Foundation
import Testing
@testable import homeclaw_cli

/// JSON row forms for `--action-json` / `--condition-json` and scene files (#87).
@Suite("JSON action and condition rows")
struct RowJSONTests {
    @Test("parses a row with a service selector, integer index carried as text")
    func parsesSelectorRow() throws {
        let row = try RowJSON.parseFlagRow(
            #"{"accessory":"Covelight","property":"power","value":"false","service_index":2}"#,
            flag: "--action-json")
        #expect(row == ["accessory": "Covelight", "property": "power", "value": "false", "service_index": "2"])
    }

    @Test("normalizes the characteristic alias and trims values")
    func normalizesAlias() throws {
        let row = try RowJSON.parseFlagRow(
            #"{"accessory":" Covelight ","characteristic":"power","value":"true","service_name":"Table Light","service_id":"ABC"}"#,
            flag: "--condition-json")
        #expect(row["property"] == "power")
        #expect(row["characteristic"] == nil)
        #expect(row["accessory"] == "Covelight")
        #expect(row["service_name"] == "Table Light")
        #expect(row["service_id"] == "ABC")
    }

    @Test("keeps colons in values, which the positional form can't carry past the split")
    func keepsColonsInNames() throws {
        let row = try RowJSON.parseFlagRow(
            #"{"accessory":"Hall: Lamp","property":"power","value":"true"}"#, flag: "--action-json")
        #expect(row["accessory"] == "Hall: Lamp")
    }

    @Test("rejects malformed rows", arguments: [
        "not json",
        #"["accessory"]"#,
        #"{"accessory":"A","property":"power"}"#,
        #"{"accessory":"A","property":"power","value":"1","service-index":2}"#,
        #"{"accessory":"A","property":"power","characteristic":"power","value":"1"}"#,
        #"{"accessory":"A","property":"power","value":true}"#,
        #"{"accessory":"","property":"power","value":"1"}"#,
        #"{"accessory":"A","property":"power","value":"1","service_index":"two"}"#,
        #"{"accessory":"A","property":"power","value":"1","service_index":0}"#,
        #"{"accessory":"A","property":"power","value":"1","service_index":1.5}"#,
        #"{"accessory":"A","property":"power","value":"1","service_index":true}"#,
        #"{"accessory":"A","property":"power","value":"1","service_name":"  "}"#,
    ])
    func rejectsMalformed(raw: String) {
        #expect(throws: ValidationError.self) {
            try RowJSON.parseFlagRow(raw, flag: "--action-json")
        }
    }

    @Test("scene file rows pass strings through and normalize the selector")
    func sceneRows() throws {
        let rows = try RowJSON.sceneActionRows([
            ["accessory": "Covelight", "characteristic": "power", "value": "0", "service_index": 2],
            ["accessory_id": "UUID", "property": "power", "value": "1", "service_id": "S"],
        ] as [Any])
        #expect(rows?[0]["service_index"] == "2")
        #expect(rows?[0]["characteristic"] == "power")
        #expect(rows?[1]["service_id"] == "S")
    }

    @Test("scene file rows reject non-string values and bad indexes")
    func sceneRowsReject() {
        #expect(throws: ValidationError.self) {
            try RowJSON.sceneActionRows([["accessory": "A", "property": "power", "value": true]] as [Any])
        }
        #expect(throws: ValidationError.self) {
            try RowJSON.sceneActionRows([["accessory": "A", "property": "power", "value": "1", "service_index": "x"]] as [Any])
        }
        #expect((try? RowJSON.sceneActionRows("nope")) == nil)
    }

    @Test("human output names the service when one is targeted")
    func targetLabel() {
        #expect(RowJSON.targetLabel(["accessory": "Covelight"]) == "Covelight")
        #expect(RowJSON.targetLabel(["accessory": "Covelight", "service_name": "Table Light"]) == "Covelight [Table Light]")
        #expect(RowJSON.targetLabel(["accessory": "Covelight", "service_name": "Covelight"]) == "Covelight")
    }

    @Test("create accepts repeatable --action-json and --condition-json")
    func createParsesJSONFlags() throws {
        let cmd = try CreateAutomation.parse([
            "--name", "Dining Off",
            "--accessory", "Dining FP2",
            "--characteristic", "occupancy_detected",
            "--trigger-value", "false",
            "--action-json", #"{"accessory":"Covelight","property":"power","value":"false","service_index":1}"#,
            "--action-json", #"{"accessory":"Covelight","property":"power","value":"false","service_index":2}"#,
            "--condition-json", #"{"accessory":"Covelight","property":"power","value":"true","service_index":2}"#,
        ])
        #expect(cmd.actionJSON.count == 2)
        #expect(cmd.conditionJSON.count == 1)
        let rows = try CreateAutomation.rows(
            positional: cmd.action, json: cmd.actionJSON, flag: "--action-json", parse: CreateAutomation.parseActionRow)
        #expect(rows.map { $0["service_index"] } == ["1", "2"])
    }

    @Test("positional rows come before JSON rows")
    func rowOrder() throws {
        let rows = try CreateAutomation.rows(
            positional: ["Lamp:power:true"],
            json: [#"{"accessory":"Covelight","property":"power","value":"false","service_index":2}"#],
            flag: "--action-json", parse: CreateAutomation.parseActionRow)
        #expect(rows.map { $0["accessory"] } == ["Lamp", "Covelight"])
    }

    @Test("create-time accepts --action-json")
    func createTimeParsesJSONFlags() throws {
        let cmd = try CreateTimeAutomation.parse([
            "--name", "Evening",
            "--time", "18:00",
            "--action-json", #"{"accessory":"Covelight","property":"power","value":"true","service_name":"Table Light"}"#,
        ])
        #expect(cmd.actionJSON.count == 1)
    }

    @Test("add-condition accepts service selector flags")
    func addConditionSelectors() throws {
        let cmd = try AddAutomationCondition.parse([
            "Porch", "--accessory", "Covelight", "--property", "power", "--value", "true",
            "--service-name", "Table Light", "--service-id", "ABC", "--service-index", "2",
        ])
        #expect(cmd.serviceName == "Table Light")
        #expect(cmd.serviceID == "ABC")
        #expect(cmd.serviceIndex == 2)
    }

    @Test("add-condition rejects a zero or empty selector")
    func addConditionRejects() {
        #expect(throws: (any Error).self) {
            try AddAutomationCondition.parse([
                "Porch", "--accessory", "A", "--property", "power", "--value", "1", "--service-index", "0",
            ])
        }
        #expect(throws: (any Error).self) {
            try AddAutomationCondition.parse([
                "Porch", "--accessory", "A", "--property", "power", "--value", "1", "--service-name", " ",
            ])
        }
    }
}
