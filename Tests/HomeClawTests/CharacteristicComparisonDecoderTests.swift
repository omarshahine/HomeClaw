import Foundation
import XCTest
@testable import HomeClaw

/// Read-only predicate reporting must preserve ordering, especially blind-open guards.
final class CharacteristicComparisonDecoderTests: XCTestCase {
    func testOrderedAndEqualityComparisonsInBothDirections() throws {
        let operators: [(NSComparisonPredicate.Operator, String, String)] = [
            (.equalTo, "==", "=="), (.notEqualTo, "!=", "!="),
            (.lessThan, "<", ">"), (.lessThanOrEqualTo, "<=", ">="),
            (.greaterThan, ">", "<"), (.greaterThanOrEqualTo, ">=", "<="),
        ]
        for (operation, forward, reverse) in operators {
            for constantOnLeft in [false, true] {
                let field = NSExpression(forKeyPath: "characteristicValue")
                let zero = NSExpression(forConstantValue: 0)
                let source = NSComparisonPredicate(leftExpression: constantOnLeft ? zero : field,
                    rightExpression: constantOnLeft ? field : zero, modifier: .direct, type: operation)
                let decoded = try XCTUnwrap(AccessoryModel.characteristicValueComparison(source))
                XCTAssertEqual(decoded.value, "0")
                XCTAssertEqual(decoded.op, constantOnLeft ? reverse : forward)
                let normalized = NSPredicate(format: "characteristicValue \(decoded.op) 0")
                for value in [-1, 0, 1, 100] {
                    let record = ["characteristicValue": value]
                    XCTAssertEqual(source.evaluate(with: record), normalized.evaluate(with: record))
                }
            }
        }
    }

    func testUnsupportedShapesStayUnknown() {
        let field = NSExpression(forKeyPath: "characteristicValue")
        let zero = NSExpression(forConstantValue: 0)
        let cases = [
            NSComparisonPredicate(leftExpression: field, rightExpression: zero, modifier: .direct, type: .contains),
            NSComparisonPredicate(leftExpression: field, rightExpression: zero, modifier: .any, type: .equalTo),
            NSComparisonPredicate(leftExpression: field, rightExpression: zero, modifier: .direct, type: .equalTo, options: .caseInsensitive),
            NSComparisonPredicate(leftExpression: zero, rightExpression: zero, modifier: .direct, type: .equalTo),
            NSComparisonPredicate(leftExpression: NSExpression(forFunction: "now", arguments: []), rightExpression: zero, modifier: .direct, type: .greaterThan),
            NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: "unrelatedField"), rightExpression: zero, modifier: .direct, type: .greaterThan),
            NSComparisonPredicate(leftExpression: zero, rightExpression: NSExpression(forKeyPath: "unrelatedField"), modifier: .direct, type: .lessThan),
            NSComparisonPredicate(leftExpression: field, rightExpression: NSExpression(forConstantValue: nil), modifier: .direct, type: .equalTo),
        ]
        for predicate in cases {
            XCTAssertNil(AccessoryModel.characteristicValueComparison(predicate))
        }
    }
}
