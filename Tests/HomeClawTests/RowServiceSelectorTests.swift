import HomeKit
import XCTest
@testable import HomeClaw

/// Service selectors on scene and automation action rows and on condition rows
/// (#87). `HMService` / `HMCharacteristic` have no public initializers, so these
/// drive the plain-value helpers the live resolver is built on, using the shape of
/// the Aqara Dual Relay T2 from the issue: one accessory, two Switch services that
/// both carry `power`.
final class RowServiceSelectorTests: XCTestCase {
    private let covelight = HomeKitManager.ServiceDescriptor(
        name: "Covelight", type: HMServiceTypeSwitch, id: "ADA239D3-0000-0000-0000-000000000001", index: 1)
    private let tableLight = HomeKitManager.ServiceDescriptor(
        name: "Table Light", type: HMServiceTypeSwitch, id: "ADA239D3-0000-0000-0000-000000000002", index: 2)

    // MARK: - Selector parsing (manager boundary)

    func testRowWithoutSelectorKeysHasEmptySelector() throws {
        let selector = try HomeKitManager.rowServiceSelector(
            from: ["accessory": "Covelight", "property": "power", "value": "false"], label: "Action 1")
        XCTAssertTrue(selector.isEmpty)
    }

    func testRowSelectorParsesAndTrims() throws {
        let selector = try HomeKitManager.rowServiceSelector(
            from: ["service_name": " Table Light ", "service_id": tableLight.id, "service_index": " 2 "],
            label: "Action 1")
        XCTAssertEqual(selector, HomeKitManager.RowServiceSelector(name: "Table Light", id: tableLight.id, index: 2))
    }

    func testRowSelectorRejectsMalformedIndex() {
        for bad in ["two", "1.5", "0", "-1", "", "  "] {
            XCTAssertThrowsError(
                try HomeKitManager.rowServiceSelector(from: ["service_index": bad], label: "Action 3"),
                "service_index '\(bad)' should be rejected"
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Action 3"), error.localizedDescription)
            }
        }
    }

    func testRowSelectorRejectsEmptyNameAndID() {
        XCTAssertThrowsError(try HomeKitManager.rowServiceSelector(from: ["service_name": "  "], label: "Condition"))
        XCTAssertThrowsError(try HomeKitManager.rowServiceSelector(from: ["service_id": ""], label: "Condition"))
    }

    func testParseServiceIndex() {
        XCTAssertEqual(HomeKitManager.parseServiceIndex("2"), 2)
        XCTAssertEqual(HomeKitManager.parseServiceIndex(" 12 "), 12)
        XCTAssertNil(HomeKitManager.parseServiceIndex("0"))
        XCTAssertNil(HomeKitManager.parseServiceIndex("2a"))
    }

    // MARK: - Socket-layer strict parsing

    func testSocketNormalizesServiceIndexFromIntegerOrString() throws {
        XCTAssertEqual(try SocketServer.normalizeServiceSelector(NSNumber(value: 2), key: "service_index", label: "x"), "2")
        XCTAssertEqual(try SocketServer.normalizeServiceSelector("3", key: "service_index", label: "x"), "3")
        XCTAssertNil(try SocketServer.normalizeServiceSelector(nil, key: "service_index", label: "x"))
    }

    func testSocketRejectsNonNumericServiceIndex() {
        for bad: Any in [NSNumber(value: true), NSNumber(value: 1.5), "abc", "0", ["2"]] {
            XCTAssertThrowsError(
                try SocketServer.normalizeServiceSelector(bad, key: "service_index", label: "'actions'[1].service_index"),
                "\(bad) should be rejected"
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("'actions'[1].service_index"))
            }
        }
    }

    func testSocketRejectsNonStringServiceName() {
        XCTAssertThrowsError(try SocketServer.normalizeServiceSelector(NSNumber(value: 2), key: "service_name", label: "x"))
        XCTAssertThrowsError(try SocketServer.normalizeServiceSelector("   ", key: "service_id", label: "x"))
        XCTAssertEqual(try SocketServer.normalizeServiceSelector(" Table Light ", key: "service_name", label: "x"), "Table Light")
    }

    func testAccessoryRowsCarrySelectorsAsStrings() throws {
        let rows = try SocketServer.parseAccessoryRowsArg([
            ["accessory": covelight.id, "property": "power", "value": "false"],
            ["accessory": covelight.id, "property": "power", "value": "false", "service_index": NSNumber(value: 2)],
            ["accessory": covelight.id, "characteristic": "power", "value": "true", "service_name": "Table Light"],
        ] as [Any], fieldName: "actions")
        XCTAssertEqual(rows?.count, 3)
        XCTAssertNil(rows?[0]["service_index"])
        XCTAssertEqual(rows?[1]["service_index"], "2")
        // The documented `characteristic` alias for `property` is accepted.
        XCTAssertEqual(rows?[2]["property"], "power")
        XCTAssertEqual(rows?[2]["service_name"], "Table Light")
    }

    func testAccessoryRowsRejectBadServiceIndex() {
        XCTAssertThrowsError(try SocketServer.parseAccessoryRowsArg([
            ["accessory": "Covelight", "property": "power", "value": "false", "service_index": "second"],
        ] as [Any], fieldName: "conditions"))
    }

    func testSceneRowsAcceptGetSceneShapeAndIntegerIndex() throws {
        let rows = try SocketServer.parseSceneActionRowsArg([
            ["accessory": "Covelight", "accessory_id": covelight.id, "room": "Dining",
             "characteristic": "power", "value": "0",
             "service_name": "Table Light", "service_id": tableLight.id, "service_index": "2"],
            ["accessory_id": covelight.id, "property": "power", "value": "0", "service_index": NSNumber(value: 1)],
        ] as [Any])
        XCTAssertEqual(rows?[0]["service_id"], tableLight.id)
        XCTAssertEqual(rows?[1]["service_index"], "1")
    }

    func testSceneRowsRejectNonStringValues() {
        XCTAssertThrowsError(try SocketServer.parseSceneActionRowsArg([
            ["accessory": "Covelight", "property": "power", "value": NSNumber(value: true)],
        ] as [Any]))
        XCTAssertNil(try SocketServer.parseSceneActionRowsArg(nil))
    }

    // MARK: - Resolution

    /// A row selector resolves to exactly the named gang, by each selector kind.
    func testSelectorResolvesExactlyOneGang() throws {
        let gangs = [covelight, tableLight]
        for row in [["service_id": tableLight.id], ["service_index": "2"], ["service_name": "table light"]] {
            let selector = try HomeKitManager.rowServiceSelector(from: row, label: "Action 1")
            let pick = HomeKitManager.pickService(from: gangs) {
                HomeKitManager.serviceMatches(
                    serviceType: $0.type, serviceName: $0.name, serviceUUID: $0.id, labelIndex: $0.index,
                    type: nil, name: selector.name, id: selector.id, index: selector.index)
            }
            guard case .found(let gang) = pick else { return XCTFail("expected one gang for \(row)") }
            XCTAssertEqual(gang, tableLight)
        }
    }

    func testSelectorMatchingNothingIsAnErrorListingCarriers() throws {
        let selector = try HomeKitManager.rowServiceSelector(from: ["service_index": "3"], label: "Action 2")
        let pick = HomeKitManager.pickService(from: [covelight, tableLight]) {
            HomeKitManager.serviceMatches(
                serviceType: $0.type, serviceName: $0.name, serviceUUID: $0.id, labelIndex: $0.index,
                type: nil, name: selector.name, id: selector.id, index: selector.index)
        }
        guard case .noMatch = pick else { return XCTFail("expected noMatch") }
        let message = HomeKitManager.rowSelectorMismatchMessage(
            rowLabel: "Action 2", accessoryName: "Covelight", property: "power", carriers: [covelight, tableLight])
        XCTAssertTrue(message.hasPrefix("Action 2:"))
        XCTAssertTrue(message.contains(covelight.selectorHint))
        XCTAssertTrue(message.contains(tableLight.selectorHint))
    }

    /// No selector on an ambiguous row keeps the old first-match result, but with a
    /// warning that names every candidate and how to address it.
    func testAmbiguityWithoutSelectorWarnsAndKeepsFirst() {
        let outcome = HomeKitManager.resolveRowAmbiguity(
            [covelight, tableLight], hasSelector: false,
            rowLabel: "Action 1", accessoryName: "Covelight", property: "power")
        guard case .useFirst(let chosen, let warning) = outcome else { return XCTFail("expected useFirst") }
        XCTAssertEqual(chosen, covelight)
        XCTAssertTrue(warning.hasPrefix("Action 1:"))
        XCTAssertTrue(warning.contains("2 services"))
        XCTAssertTrue(warning.contains(#"service_name: "Table Light""#))
        XCTAssertTrue(warning.contains("service_index: 2"))
        XCTAssertTrue(warning.contains("service_id: \(tableLight.id)"))
    }

    func testAmbiguityWithSelectorFails() {
        let outcome = HomeKitManager.resolveRowAmbiguity(
            [covelight, tableLight], hasSelector: true,
            rowLabel: "Condition", accessoryName: "Covelight", property: "power")
        guard case .fail(let message) = outcome else { return XCTFail("expected fail") }
        XCTAssertTrue(message.contains("service_id"))
    }

    // MARK: - Duplicate detection

    /// The Dual Relay report: two `power` actions on one accessory, one per gang,
    /// must both survive. The same gang twice is still a duplicate.
    func testDuplicateKeyIncludesTheService() {
        let gang1 = HomeKitManager.ActionTargetKey(
            accessoryID: "ACC", serviceID: covelight.id, characteristicType: HMCharacteristicTypePowerState)
        let gang2 = HomeKitManager.ActionTargetKey(
            accessoryID: "ACC", serviceID: tableLight.id, characteristicType: HMCharacteristicTypePowerState)
        XCTAssertNil(HomeKitManager.firstDuplicateTarget([gang1, gang2]))
        XCTAssertEqual(HomeKitManager.firstDuplicateTarget([gang1, gang2, gang1]), 2)
    }

    // MARK: - Read-side emission

    func testReadSideOmitsSelectorOnSingleServiceAccessories() {
        XCTAssertEqual(
            AccessoryModel.serviceSelectorFields(name: "Lamp", id: "L", index: nil, carrierCount: 1), [:])
    }

    func testReadSideEmitsSelectorOnMultiGangAccessories() {
        XCTAssertEqual(
            AccessoryModel.serviceSelectorFields(name: "Table Light", id: tableLight.id, index: 2, carrierCount: 2),
            ["service_name": "Table Light", "service_id": tableLight.id, "service_index": "2"])
        XCTAssertEqual(
            AccessoryModel.serviceSelectorFields(name: "Switch 2", id: "S2", index: nil, carrierCount: 2),
            ["service_name": "Switch 2", "service_id": "S2"])
    }

    /// What the read side emits is what the write side accepts.
    func testReadSideFieldsRoundTripThroughTheWriteParser() throws {
        let fields = AccessoryModel.serviceSelectorFields(
            name: "Table Light", id: tableLight.id, index: 2, carrierCount: 2)
        let selector = try HomeKitManager.rowServiceSelector(from: fields, label: "Action 1")
        XCTAssertEqual(selector, HomeKitManager.RowServiceSelector(name: "Table Light", id: tableLight.id, index: 2))
    }
}
