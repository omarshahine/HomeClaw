import Foundation
import HomeKit
import XCTest
@testable import HomeClaw

/// Operand rules for characteristic conditions: which (operator, value, characteristic)
/// combinations are written and which are refused, plus the row-shape validation and
/// normalisation every create/create-time/edit entry point runs before the demo branch.
/// `HMCharacteristic` has no public initializer, so the live checks are exercised
/// through their plain-value cores (metadata format passed as a string).
final class ConditionOperandValidationTests: XCTestCase {
    private func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Metadata-aware operand parsing (F1)

    /// `current_temperature` is outside the hardcoded numeric list, so the action parser
    /// reads "0" as `false`. On a numeric characteristic it must be the number 0.
    func testZeroAndOneAreNumbersOnNumericCharacteristics() {
        for format in [HMCharacteristicMetadataFormatFloat, HMCharacteristicMetadataFormatInt,
                       HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
                       HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64] {
            for raw in ["0", "1", " 0 "] {
                let parsed = HomeKitManager.numericConditionOperand(raw, format: format)
                XCTAssertNotNil(parsed, "\(raw) on \(format)")
                XCTAssertFalse(isBoolean(parsed), "\(raw) on \(format) must not be a boolean")
            }
        }
        XCTAssertEqual(HomeKitManager.numericConditionOperand("0", format: HMCharacteristicMetadataFormatFloat)?.intValue, 0)
        XCTAssertEqual(HomeKitManager.numericConditionOperand("-5", format: HMCharacteristicMetadataFormatFloat)?.intValue, -5)
    }

    func testNonNumericOrUnknownFormatsFallBackToTheActionParser() {
        XCTAssertNil(HomeKitManager.numericConditionOperand("0", format: HMCharacteristicMetadataFormatBool))
        XCTAssertNil(HomeKitManager.numericConditionOperand("1", format: HMCharacteristicMetadataFormatString))
        XCTAssertNil(HomeKitManager.numericConditionOperand("0", format: nil))
        XCTAssertNil(HomeKitManager.numericConditionOperand("on", format: HMCharacteristicMetadataFormatFloat))
        XCTAssertNil(HomeKitManager.numericConditionOperand("21.5", format: HMCharacteristicMetadataFormatFloat))
    }

    func testOrderedComparisonAgainstZeroIsAcceptedOnANumericCharacteristic() throws {
        let parsed = try XCTUnwrap(HomeKitManager.numericConditionOperand("0", format: HMCharacteristicMetadataFormatFloat))
        XCTAssertNil(HomeKitManager.conditionOperandRejection(
            .lessThan, parsed: parsed, property: "current_temperature", format: HMCharacteristicMetadataFormatFloat))
    }

    // MARK: - Characteristic format checks (F3)

    func testOrderedComparisonOnBoolCharacteristicIsRejected() throws {
        let message = try XCTUnwrap(HomeKitManager.conditionOperandRejection(
            .lessThan, parsed: NSNumber(value: 50), property: "power", format: HMCharacteristicMetadataFormatBool))
        XCTAssertTrue(message.contains("on/off"), message)
    }

    func testOrderedComparisonOnNonNumericFormatsIsRejected() throws {
        for format in [HMCharacteristicMetadataFormatString, HMCharacteristicMetadataFormatData,
                       HMCharacteristicMetadataFormatTLV8] {
            let message = try XCTUnwrap(HomeKitManager.conditionOperandRejection(
                .greaterThan, parsed: NSNumber(value: 1), property: "name", format: format), format)
            XCTAssertTrue(message.contains(format), message)
        }
    }

    func testMissingMetadataRejectsUnlessThePropertyIsKnownNumeric() throws {
        let message = try XCTUnwrap(HomeKitManager.conditionOperandRejection(
            .lessThan, parsed: NSNumber(value: 50), property: "power", format: nil))
        XCTAssertTrue(message.contains("no format metadata"), message)
        XCTAssertNil(HomeKitManager.conditionOperandRejection(
            .lessThan, parsed: NSNumber(value: 30), property: "current_light_level", format: nil))
    }

    func testBooleanOperandIsRejectedEvenOnANumericCharacteristic() throws {
        let message = try XCTUnwrap(HomeKitManager.conditionOperandRejection(
            .greaterThanOrEqual, parsed: NSNumber(value: true), property: "brightness",
            format: HMCharacteristicMetadataFormatInt))
        XCTAssertTrue(message.contains("boolean"), message)
    }

    func testEqualityAndInequalityAreAllowedOnEveryFormat() {
        for format in [HMCharacteristicMetadataFormatBool, HMCharacteristicMetadataFormatString, nil] {
            for comparison in [ConditionComparison.equal, .notEqual] {
                XCTAssertNil(HomeKitManager.conditionOperandRejection(
                    comparison, parsed: NSNumber(value: true), property: "power", format: format))
            }
        }
    }

    // MARK: - On/off tokens (F2, metadata-free, demo and live)

    func testBooleanTokensAreRejectedUnderOrderedComparisonsOnly() {
        for token in ["on", "OFF", "true", " False "] {
            XCTAssertNotNil(ConditionComparison.booleanTokenRejection(.lessThan, value: token, property: "power"), token)
            XCTAssertNil(ConditionComparison.booleanTokenRejection(.equal, value: token, property: "power"), token)
            XCTAssertNil(ConditionComparison.booleanTokenRejection(.notEqual, value: token, property: "power"), token)
        }
        // "0"/"1" need metadata to classify, so the token check leaves them alone.
        XCTAssertNil(ConditionComparison.booleanTokenRejection(.lessThan, value: "1", property: "power"))
        XCTAssertNil(ConditionComparison.booleanTokenRejection(.greaterThan, value: "30", property: "current_light_level"))
    }

    // MARK: - validateConditionRowShapes

    @MainActor
    func testRowShapesAcceptWellFormedRows() throws {
        try HomeKitManager.validateConditionRowShapes([
            ["accessory": "Lux", "property": "current_light_level", "value": "<30"],
            ["accessory": "Lux", "property": "current_light_level", "value": "30", "operator": "lte"],
            ["accessory": "Lamp", "property": "power", "value": "on"],
            ["accessory": "Lamp", "property": "power", "value": "off", "operator": "!="],
            ["accessory": "Lamp", "characteristic": "power", "value": "true"],
        ])
        try HomeKitManager.validateConditionRowShapes([])
    }

    @MainActor
    func testRowShapesRejectMalformedOperators() {
        let bad: [[String: String]] = [
            ["property": "current_light_level", "value": "<"],
            ["property": "current_light_level", "value": "30", "operator": "ltt"],
            ["property": "current_light_level", "value": "<30", "operator": "=="],
        ]
        for row in bad {
            XCTAssertThrowsError(try HomeKitManager.validateConditionRowShapes([row]), "\(row)")
        }
    }

    @MainActor
    func testRowShapesRejectOrderedComparisonAgainstOnOffToken() {
        let bad: [[String: String]] = [
            ["property": "power", "value": "<on"],
            ["property": "power", "value": "true", "operator": "<"],
            ["property": "power", "value": "false", "operator": "gt"],
            ["property": "power", "value": ">= OFF"],
        ]
        for row in bad {
            XCTAssertThrowsError(try HomeKitManager.validateConditionRowShapes([row]), "\(row)") { error in
                XCTAssertTrue(error.localizedDescription.contains("needs a numeric value"), error.localizedDescription)
            }
        }
    }

    // MARK: - normalizedConditionRows

    @MainActor
    func testNormalizedRowsCarryCanonicalOperatorAndBareValue() {
        let input: [[String: String]] = [
            ["accessory": "Lux", "property": "current_light_level", "value": "<30",
             "service_index": "2", "service_name": "Sensor", "room": "Den"],
            ["accessory": "Lux", "property": "current_light_level", "value": " 30 ", "operator": "gte"],
            ["accessory": "Lamp", "property": "power", "value": "on"],
        ]
        let output = HomeKitManager.normalizedConditionRows(input)
        XCTAssertEqual(output[0]["operator"], "<")
        XCTAssertEqual(output[0]["value"], "30")
        XCTAssertEqual(output[0]["service_index"], "2")
        XCTAssertEqual(output[0]["service_name"], "Sensor")
        XCTAssertEqual(output[0]["room"], "Den")
        XCTAssertEqual(output[0]["accessory"], "Lux")
        XCTAssertEqual(output[1]["operator"], ">=")
        XCTAssertEqual(output[1]["value"], "30")
        XCTAssertEqual(output[2]["operator"], "==")
        XCTAssertEqual(output[2]["value"], "on")
        // The caller's rows are untouched.
        XCTAssertEqual(input[0]["value"], "<30")
        XCTAssertNil(input[0]["operator"])
        XCTAssertEqual(input[1]["operator"], "gte")
    }

    @MainActor
    func testNormalizedRowsLeaveUnresolvableRowsAsGiven() {
        let row = ["property": "current_light_level", "value": "<30", "operator": "=="]
        XCTAssertEqual(HomeKitManager.normalizedConditionRows([row]), [row])
    }

    // MARK: - Operator wire argument (shared by socket, add-condition, app MCP)

    func testOperatorArgTreatsNullAsAbsent() {
        XCTAssertEqual(ConditionComparison.parseOperatorArg(nil), .absent)
        XCTAssertEqual(ConditionComparison.parseOperatorArg(NSNull()), .absent)
        XCTAssertEqual(ConditionComparison.parseOperatorArg(" lt "), .comparison(.lessThan))
        XCTAssertEqual(ConditionComparison.parseOperatorArg(NSNumber(value: 5)), .notString)
        XCTAssertEqual(ConditionComparison.parseOperatorArg(NSNumber(value: true)), .notString)
        XCTAssertEqual(ConditionComparison.parseOperatorArg("   "), .empty)
        XCTAssertEqual(ConditionComparison.parseOperatorArg("ltt"), .unknown("ltt"))
    }

    // MARK: - App MCP add_condition (ToolHandlers)

    func testNativeAddConditionParsesOperator() throws {
        XCTAssertNil(try ToolHandlers.addConditionComparison([:]))
        XCTAssertNil(try ToolHandlers.addConditionComparison(["operator": NSNull()]))
        XCTAssertEqual(try ToolHandlers.addConditionComparison(["operator": "lt"]), .lessThan)
        XCTAssertEqual(try ToolHandlers.addConditionComparison(["operator": "lte"]), .lessThanOrEqual)
        XCTAssertEqual(try ToolHandlers.addConditionComparison(["operator": " gt "]), .greaterThan)
        XCTAssertEqual(try ToolHandlers.addConditionComparison(["operator": "gte"]), .greaterThanOrEqual)
        XCTAssertEqual(try ToolHandlers.addConditionComparison(["operator": "!="]), .notEqual)
    }

    func testNativeAddConditionRejectsBadOperators() {
        for bad: Any in [NSNumber(value: 5), NSNumber(value: true), "", "  ", ["<"]] {
            XCTAssertThrowsError(try ToolHandlers.addConditionComparison(["operator": bad]), "\(bad)") { error in
                XCTAssertTrue(error.localizedDescription.contains("condition.operator"), error.localizedDescription)
            }
        }
        XCTAssertThrowsError(try ToolHandlers.addConditionComparison(["operator": "ltt"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("'ltt'"), error.localizedDescription)
        }
    }

    @MainActor
    func testPlainEmptyValueIsNotBlamedOnAnOperator() {
        // A row that never named an operator should not be told it "has operator '=='".
        XCTAssertThrowsError(
            try HomeKitManager.validateConditionRowShapes([["property": "power", "value": ""]])
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("non-empty value"), message)
            XCTAssertFalse(message.contains("has operator"), message)
        }
    }

    @MainActor
    func testNamedOperatorWithEmptyValueStillBlamesTheOperator() {
        XCTAssertThrowsError(
            try HomeKitManager.validateConditionRowShapes(
                [["property": "current_light_level", "value": "", "operator": "<"]])
        ) { error in
            XCTAssertTrue("\(error)".contains("has operator"), "\(error)")
        }
    }

    func testOnlyOrderedComparisonsUseNumericMetadata() {
        // The metadata-driven numeric parse exists to stop `current_temperature < 0` becoming
        // `< false`. Applying it to equality too would change the operand type of existing
        // `occupancy_detected == 1` rows, which this change promises not to touch.
        XCTAssertTrue(ConditionComparison.lessThan.requiresNumericOperand)
        XCTAssertTrue(ConditionComparison.greaterThanOrEqual.requiresNumericOperand)
        XCTAssertFalse(ConditionComparison.equal.requiresNumericOperand)
        XCTAssertFalse(ConditionComparison.notEqual.requiresNumericOperand)

        // The gate itself: ordered comparisons get the number, equality keeps the old path.
        XCTAssertNotNil(HomeKitManager.orderedNumericConditionOperand(
            "1", format: HMCharacteristicMetadataFormatFloat, comparison: .lessThan))
        XCTAssertNotNil(HomeKitManager.orderedNumericConditionOperand(
            "0", format: HMCharacteristicMetadataFormatInt, comparison: .greaterThanOrEqual))
        XCTAssertNil(HomeKitManager.orderedNumericConditionOperand(
            "1", format: HMCharacteristicMetadataFormatFloat, comparison: .equal),
            "equality must keep parseActionValue's boolean coercion")
        XCTAssertNil(HomeKitManager.orderedNumericConditionOperand(
            "1", format: HMCharacteristicMetadataFormatFloat, comparison: .notEqual))

        // The helper underneath is metadata-driven and operator-agnostic.
        XCTAssertNotNil(HomeKitManager.numericConditionOperand("1", format: HMCharacteristicMetadataFormatFloat))
        XCTAssertNil(HomeKitManager.numericConditionOperand("1", format: HMCharacteristicMetadataFormatBool))
        XCTAssertNil(HomeKitManager.numericConditionOperand("inf", format: HMCharacteristicMetadataFormatFloat))
        XCTAssertNil(HomeKitManager.numericConditionOperand("1", format: nil))
    }
}
