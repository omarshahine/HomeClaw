import Testing
@testable import homeclaw_cli

/// CLI-layer coverage for condition comparison operators.
///
/// The app target owns the authoritative parse (`ConditionComparison`) and the socket
/// re-validates every row; these tests pin the CLI's half: splitting a symbolic prefix
/// off `--condition`, normalizing `--operator` spellings, and rejecting a typo before a
/// socket round-trip. Mirrors how `--time-after`/`--time-before` are validated at each
/// layer rather than only at the end.
@Suite("Condition comparison operators (CLI)")
struct ConditionOperatorTests {
    @Test("symbolic prefix moves out of the value into operator")
    func prefixBecomesOperator() throws {
        let parsed = try CreateAutomation.parseConditionRow("Lux:current_light_level:<30")
        #expect(parsed["accessory"] == "Lux")
        #expect(parsed["property"] == "current_light_level")
        #expect(parsed["value"] == "30")
        #expect(parsed["operator"] == "<")
    }

    @Test("two-character comparisons win over their one-character prefix")
    func longestPrefixWins() throws {
        let lte = try CreateAutomation.parseConditionRow("Lux:current_light_level:<=30")
        #expect(lte["operator"] == "<=")
        #expect(lte["value"] == "30")

        let gte = try CreateAutomation.parseConditionRow("Lux:current_light_level:>=30")
        #expect(gte["operator"] == ">=")
        #expect(gte["value"] == "30")
    }

    @Test("rows without a prefix stay equality rows")
    func plainRowsUnchanged() throws {
        let parsed = try CreateAutomation.parseConditionRow("Front Door:contact_state:0")
        #expect(parsed["operator"] == nil)
        #expect(parsed["value"] == "0")
    }

    @Test("naked comparison operator rejected as a value")
    func nakedOperatorRejected() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow("Lux:current_light_level:<")
        }
    }

    @Test("mnemonics and symbols normalize to one canonical spelling")
    func normalization() {
        #expect(RowJSON.normalizedComparisonOperator("lt") == "<")
        #expect(RowJSON.normalizedComparisonOperator("LTE") == "<=")
        #expect(RowJSON.normalizedComparisonOperator("  >=  ") == ">=")
        #expect(RowJSON.normalizedComparisonOperator("eq") == "==")
        #expect(RowJSON.normalizedComparisonOperator("ne") == "!=")
        #expect(RowJSON.normalizedComparisonOperator("ltt") == nil)
        #expect(RowJSON.normalizedComparisonOperator("") == nil)
    }

    @Test("--operator is validated at the CLI boundary")
    func addConditionValidatesOperator() throws {
        let ok = try AddAutomationCondition.parse([
            "Porch Lights",
            "--accessory", "Lux",
            "--property", "current_light_level",
            "--value", "30",
            "--operator", "lte",
        ])
        #expect(ok.comparisonOperator == "lte")

        #expect(throws: (any Error).self) {
            _ = try AddAutomationCondition.parse([
                "Porch Lights",
                "--accessory", "Lux",
                "--property", "current_light_level",
                "--value", "30",
                "--operator", "ltt",
            ])
        }
    }

    @Test("condition JSON operator is validated at the CLI, not after a round-trip")
    func conditionJSONValidatesOperator() {
        #expect(throws: (any Error).self) {
            _ = try RowJSON.parseFlagRow(
                #"{"accessory":"Lux","property":"current_light_level","value":"30","operator":"ltt"}"#,
                flag: "--condition-json")
        }
        // Mnemonic is accepted and normalized to the canonical symbol.
        let row = try? RowJSON.parseFlagRow(
            #"{"accessory":"Lux","property":"current_light_level","value":"30","operator":" lt "}"#,
            flag: "--condition-json")
        #expect(row?["operator"] == "<")
    }

    @Test("operator plus a comparison prefix on the value is rejected as contradictory")
    func explicitOperatorWithPrefixRejected() {
        #expect(throws: (any Error).self) {
            _ = try RowJSON.parseFlagRow(
                #"{"accessory":"Lux","property":"current_light_level","value":"<30","operator":"=="}"#,
                flag: "--condition-json")
        }
    }

    @Test("operator on an action row is rejected rather than silently dropped")
    func actionRowRejectsOperator() {
        #expect(throws: (any Error).self) {
            _ = try RowJSON.parseFlagRow(
                #"{"accessory":"Lamp","property":"power","value":"true","operator":"<"}"#,
                flag: "--action-json")
        }
    }

    @Test("condition JSON rows may carry an operator")
    func conditionJSONAcceptsOperator() throws {
        let row = try RowJSON.parseFlagRow(
            #"{"accessory":"Lux","property":"current_light_level","value":"30","operator":"<"}"#,
            flag: "--condition-json"
        )
        #expect(row["operator"] == "<")
        #expect(row["value"] == "30")
    }

    @Test("string values starting with a comparison character stay literal")
    func stringValuesAreNotSplit() throws {
        // The app refuses to peel a prefix unless a number follows, so the CLI must agree:
        // otherwise it sends `<` with value `none` for a row the user meant literally, and
        // the add-condition warning fires on a value that has no operator in it.
        let none = try CreateAutomation.parseConditionRow("Door:status:<none>")
        #expect(none["value"] == "<none>")
        #expect(none["operator"] == nil)

        let bang = try CreateAutomation.parseConditionRow("Door:status:!=x")
        #expect(bang["value"] == "!=x")
        #expect(bang["operator"] == nil)

        #expect(RowJSON.splitComparisonPrefix("<none>") == nil)
        #expect(RowJSON.splitComparisonPrefix(">unknown") == nil)
    }

    @Test("numeric prefixes still split, including a percent sign")
    func numericPrefixesSplit() throws {
        #expect(RowJSON.splitComparisonPrefix("<30")?.op == "<")
        #expect(RowJSON.splitComparisonPrefix("<30")?.value == "30")
        #expect(RowJSON.splitComparisonPrefix(">=-5")?.value == "-5")
        #expect(RowJSON.splitComparisonPrefix("<=30%")?.value == "30%")

        let percent = try CreateAutomation.parseConditionRow("Lux:current_light_level:<30%")
        #expect(percent["operator"] == "<")
        #expect(percent["value"] == "30%")
    }

    @Test("a bare operator still reports that it has no value")
    func bareOperatorStillSplits() {
        #expect(RowJSON.splitComparisonPrefix("<")?.value == "")
        #expect(RowJSON.splitComparisonPrefix("<=")?.value == "")
    }

    @Test("non-finite and hex text is not treated as a threshold")
    func nonFiniteTextStaysLiteral() throws {
        #expect(RowJSON.splitComparisonPrefix("<inf") == nil)
        #expect(RowJSON.splitComparisonPrefix(">nan") == nil)
        #expect(RowJSON.splitComparisonPrefix("<0x1p3") == nil)
        #expect(RowJSON.isDecimalThreshold("inf") == false)
        #expect(RowJSON.isDecimalThreshold("1.2.3") == false)

        let row = try CreateAutomation.parseConditionRow("Door:status:<inf")
        #expect(row["value"] == "<inf")
        #expect(row["operator"] == nil)
    }

    @Test("a boolean token after an operator still splits so the app can refuse it")
    func booleanTokenAfterOperatorSplits() throws {
        #expect(RowJSON.splitComparisonPrefix("<on")?.op == "<")
        #expect(RowJSON.splitComparisonPrefix("<on")?.value == "on")
        #expect(RowJSON.splitComparisonPrefix(">= OFF")?.value == "OFF")
        #expect(RowJSON.isBooleanToken("true") == true)
        #expect(RowJSON.isBooleanToken("<none>") == false)

        // `<none>` is not a token, so it stays a literal value.
        let row = try CreateAutomation.parseConditionRow("Door:status:<none>")
        #expect(row["value"] == "<none>")
        #expect(row["operator"] == nil)
    }
}
