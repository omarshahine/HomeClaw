import Foundation
import XCTest
@testable import HomeClaw

/// `ConditionComparison` is the only vocabulary HomeClaw writes for a characteristic
/// condition's relation. Ordered comparisons are new (HomeKit always supported them —
/// the predicate factory accepts every operator except the string-matching ones), so
/// the parsing rules and the operator mapping are load-bearing: a typo that silently
/// fell back to equality would ship a rule that fires when the user asked for a gate.
final class ConditionComparisonTests: XCTestCase {
    func testParsesSymbolsAndMnemonics() {
        let cases: [(String, ConditionComparison?)] = [
            ("==", .equal), ("eq", .equal),
            ("!=", .notEqual), ("ne", .notEqual), ("neq", .notEqual),
            ("<", .lessThan), ("lt", .lessThan), ("lessThan", .lessThan),
            ("<=", .lessThanOrEqual), ("lte", .lessThanOrEqual), ("le", .lessThanOrEqual),
            (">", .greaterThan), ("gt", .greaterThan),
            (">=", .greaterThanOrEqual), ("gte", .greaterThanOrEqual), ("ge", .greaterThanOrEqual),
            // Not accepted: `=` is an assignment-looking value, not a comparison the
            // decoder ever reports, so accepting it would break round-tripping.
            ("=", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ConditionComparison.parse(raw), expected, "raw: \(raw)")
        }
    }

    func testParsingIsCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertEqual(ConditionComparison.parse("  LT  "), .lessThan)
        XCTAssertEqual(ConditionComparison.parse("lte"), .lessThanOrEqual)
        XCTAssertEqual(ConditionComparison.parse("\t>=\n"), .greaterThanOrEqual)
        XCTAssertEqual(ConditionComparison.parse("<= "), .lessThanOrEqual)
    }

    func testUnknownOperatorsAreRejectedRatherThanDefaulted() {
        for raw in ["ltt", "<>", "", "   ", "less-than", "<<", "=>", "="] {
            XCTAssertNil(ConditionComparison.parse(raw), "should reject: '\(raw)'")
        }
    }

    func testOperatorMappingMatchesAPISymbol() {
        let expected: [(ConditionComparison, NSComparisonPredicate.Operator)] = [
            (.equal, .equalTo), (.notEqual, .notEqualTo),
            (.lessThan, .lessThan), (.lessThanOrEqual, .lessThanOrEqualTo),
            (.greaterThan, .greaterThan), (.greaterThanOrEqual, .greaterThanOrEqualTo),
        ]
        XCTAssertEqual(expected.count, ConditionComparison.allCases.count)
        for (comparison, predicateOperator) in expected {
            XCTAssertEqual(comparison.nsOperator, predicateOperator)
        }
    }

    func testAllCasesRoundTripThroughTheirOwnAPISpelling() {
        // `automations get` reports `operator: "<"`; feeding that back must produce the
        // same comparison, which is what makes a read/modify/write round trip safe.
        for comparison in ConditionComparison.allCases {
            XCTAssertEqual(ConditionComparison.parse(comparison.apiValue), comparison)
        }
    }

    func testSplitValuePrefixUsesLongestPrefix() {
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<30")?.comparison, .lessThan)
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<30")?.value, "30")
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<=30")?.comparison, .lessThanOrEqual)
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<=30")?.value, "30")
        XCTAssertEqual(ConditionComparison.splitValuePrefix(">=30")?.comparison, .greaterThanOrEqual)
        XCTAssertEqual(ConditionComparison.splitValuePrefix(">=30")?.value, "30")
        XCTAssertEqual(ConditionComparison.splitValuePrefix("==1")?.comparison, .equal)
        XCTAssertEqual(ConditionComparison.splitValuePrefix("!=1")?.comparison, .notEqual)
        XCTAssertEqual(ConditionComparison.splitValuePrefix("> 30")?.value, "30")
    }

    func testSplitValuePrefixReturnsNilWithoutAnOperator() {
        // Plain values must be untouched, including negative numbers and strings that
        // merely contain a comparison character later in the value.
        XCTAssertNil(ConditionComparison.splitValuePrefix("30"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("-5"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("a<b"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("true"))
    }

    func testResolutionPrefersAPrefixOnlyWhenNoOperatorWasNamed() {
        // The case that used to be silent: naming `==` while also leaving a prefix on the
        // value is contradictory. Guessing either way writes a rule the caller did not ask
        // for, so it is reported and every entry point fails on it.
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: nil, value: "<30"),
            .ok(comparison: .lessThan, value: "30"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "lte", value: "30"),
            .ok(comparison: .lessThanOrEqual, value: "30"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "==", value: "<30"),
            .conflict(comparison: .equal, value: "<30"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "<", value: "<30"),
            .conflict(comparison: .lessThan, value: "<30"))
    }

    func testResolutionDefaultsToEqualityAndPreservesPlainValues() {
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: nil, value: "0"),
            .ok(comparison: .equal, value: "0"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: nil, value: " true "),
            .ok(comparison: .equal, value: "true"))
    }

    func testResolutionReportsUnknownOperatorsRatherThanDefaulting() {
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "ltt", value: "30"),
            .unknownOperator("ltt"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "  ", value: "30"),
            .unknownOperator(""))
    }

    func testOnlyOrderedComparisonsRequireANumericOperand() {
        XCTAssertTrue(ConditionComparison.lessThan.requiresNumericOperand)
        XCTAssertTrue(ConditionComparison.lessThanOrEqual.requiresNumericOperand)
        XCTAssertTrue(ConditionComparison.greaterThan.requiresNumericOperand)
        XCTAssertTrue(ConditionComparison.greaterThanOrEqual.requiresNumericOperand)
        XCTAssertFalse(ConditionComparison.equal.requiresNumericOperand)
        XCTAssertFalse(ConditionComparison.notEqual.requiresNumericOperand)
    }

    func testSplitValuePrefixReportsEmptyRemainderForCallerToReject() {
        // A naked operator is not "no prefix" — the caller must see it and fail loud
        // rather than passing "<" through as a literal value.
        let split = ConditionComparison.splitValuePrefix("<")
        XCTAssertNotNil(split)
        XCTAssertEqual(split?.comparison, .lessThan)
        XCTAssertEqual(split?.value, "")
    }

    func testStringValuesStartingWithAComparisonCharacterAreLeftAlone() {
        // A string characteristic can legitimately hold "<none>" or "!=x". Peeling those
        // would rewrite an existing equality condition into a comparison, and naming `==`
        // explicitly is rejected as a conflict, so the value would be inexpressible.
        XCTAssertNil(ConditionComparison.splitValuePrefix("<none>"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("!=x"))
        XCTAssertNil(ConditionComparison.splitValuePrefix(">unknown"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: "==", value: "<none>"),
            .ok(comparison: .equal, value: "<none>"))
        XCTAssertEqual(
            ConditionComparison.resolve(explicitOperator: nil, value: "<none>"),
            .ok(comparison: .equal, value: "<none>"))
    }

    func testNumericPrefixesStillSplitIncludingPercent() {
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<30")?.value, "30")
        XCTAssertEqual(ConditionComparison.splitValuePrefix(">=-5")?.value, "-5")
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<=30%")?.value, "30%")
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<30%")?.comparison, .lessThan)
    }

    func testNonFiniteAndHexTextIsNotTreatedAsAThreshold() {
        // Double("inf") and Double("0x1p3") both succeed, so a Double-based check would still
        // peel these into comparisons and rewrite a string value.
        XCTAssertNil(ConditionComparison.splitValuePrefix("<inf"))
        XCTAssertNil(ConditionComparison.splitValuePrefix(">nan"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("<=infinity"))
        XCTAssertNil(ConditionComparison.splitValuePrefix("<0x1p3"))
        XCTAssertFalse(ConditionComparison.isDecimalThreshold("inf"))
        XCTAssertFalse(ConditionComparison.isDecimalThreshold("nan"))
        XCTAssertFalse(ConditionComparison.isDecimalThreshold(""))
        XCTAssertFalse(ConditionComparison.isDecimalThreshold("."))
        XCTAssertFalse(ConditionComparison.isDecimalThreshold("1.2.3"))
        XCTAssertTrue(ConditionComparison.isDecimalThreshold("30"))
        XCTAssertTrue(ConditionComparison.isDecimalThreshold("-4.5"))
        XCTAssertTrue(ConditionComparison.isDecimalThreshold("+7"))
    }

    func testBooleanTokensAfterAnOperatorStillSplit() {
        // `<on` is a mistaken threshold, not a string value. Peeling it lets the caller hear
        // "on/off values only support == and !=" instead of silently comparing against "<on".
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<on")?.comparison, .lessThan)
        XCTAssertEqual(ConditionComparison.splitValuePrefix("<on")?.value, "on")
        XCTAssertEqual(ConditionComparison.splitValuePrefix(">= OFF")?.value, "OFF")
        XCTAssertEqual(ConditionComparison.splitValuePrefix(">false")?.comparison, .greaterThan)
        XCTAssertNotNil(
            ConditionComparison.booleanTokenRejection(.lessThan, value: "on", property: "power"))
        // ...while a non-token string is still left alone.
        XCTAssertNil(ConditionComparison.splitValuePrefix("<none>"))
    }
}
