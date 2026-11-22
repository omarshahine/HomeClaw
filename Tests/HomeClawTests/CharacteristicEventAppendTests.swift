import Foundation
#if !EVENT_APPEND_STANDALONE
import XCTest
@testable import HomeClaw
#endif

@MainActor
private func verifyCharacteristicEventAppend() async throws {
    struct Failure: Error { let text: String }
    func expect(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        if !condition() { throw Failure(text: text) }
    }
    let first = NSObject(), second = NSObject(), added = NSObject(), predicate = NSObject()
    let a = CharacteristicEventAppend.Event(id: "a", signature: "calendar:06:30", characteristicID: nil, value: nil)
    let b = CharacteristicEventAppend.Event(id: "b", signature: "characteristic", characteristicID: "old-sensor", value: "number:1")
    let c = CharacteristicEventAppend.Event(id: "c", signature: "characteristic", characteristicID: "new-sensor", value: "number:1")
    let guards = ["predicate": String(describing: ObjectIdentifier(predicate)), "opaque_format": "opaque clock AND sunset OR presence",
                  "action_sets": "shared-visible,hidden", "enabled": "true", "execute_once": "false", "end_events": "duration:300", "recurrences": "2,3,4", "session": "original"]
    let before = CharacteristicEventAppend.Snapshot(homeID: "home", triggerID: "trigger", events: [a,b], guards: guards, unsupported: [])
    let expected = CharacteristicEventAppend.Snapshot(homeID: "home", triggerID: "trigger", events: [a,b,c], guards: guards, unsupported: [])
    var current = before, writes = 0
    let fingerprint = before.fingerprint(adding: c)
    let preview = try await CharacteristicEventAppend.run(before: before, addition: c,
        originalObjects: [first,second], newObject: added, apply: false, expectedFingerprint: nil,
        reread: { current }, write: { _ in writes += 1 })
    try expect(preview.status == "preview" && writes == 0, "preview wrote")
    let applied = try await CharacteristicEventAppend.run(before: before, addition: c,
        originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
        reread: { current }, write: { events in
            writes += 1
            try expect(events.count == 3 && events[0] === first && events[1] === second && events[2] === added, "event identity/order lost")
            current = expected
        })
    try expect(applied.status == "verified" && writes == 1 && current.guards == guards, "append or guards changed")
    for changed in [
        CharacteristicEventAppend.Event(id: "new-id", signature: "characteristic", characteristicID: "other-sensor", value: "number:1"),
        CharacteristicEventAppend.Event(id: "new-id", signature: "characteristic", characteristicID: "new-sensor", value: "number:0"),
    ] {
        current = before; writes = 0
        do {
            _ = try await CharacteristicEventAppend.run(before: before, addition: changed, originalObjects: [first,second], newObject: added,
                apply: true, expectedFingerprint: fingerprint, reread: { current }, write: { _ in writes += 1 })
            throw Failure(text: "fingerprint did not bind the proposal")
        } catch CharacteristicEventAppend.Invalid.stale { }
        try expect(writes == 0, "changed proposal wrote")
    }
    for expectedFingerprint in [nil, "stale"] as [String?] {
        writes = 0
        do {
            _ = try await CharacteristicEventAppend.run(before: before, addition: c, originalObjects: [first,second], newObject: added,
                apply: true, expectedFingerprint: expectedFingerprint, reread: { before }, write: { _ in writes += 1 })
            throw Failure(text: "missing/stale fingerprint accepted")
        } catch is CharacteristicEventAppend.Invalid { }
        try expect(writes == 0, "bad fingerprint wrote")
    }
    for duplicate in [b, .init(id: "different-id", signature: "characteristic", characteristicID: "old-sensor", value: "number:1")] {
        writes = 0
        do {
            _ = try await CharacteristicEventAppend.run(before: before, addition: duplicate, originalObjects: [first,second], newObject: added,
                apply: false, expectedFingerprint: nil, reread: { before }, write: { _ in writes += 1 })
            throw Failure(text: "duplicate accepted")
        } catch CharacteristicEventAppend.Invalid.duplicate { }
        try expect(writes == 0, "duplicate wrote")
    }
    let any = CharacteristicEventAppend.Snapshot(homeID: "home", triggerID: "trigger", events: [.init(id: "any", signature: "characteristic", characteristicID: "new-sensor", value: "any_change")], guards: guards, unsupported: [])
    do {
        _ = try await CharacteristicEventAppend.run(before: any, addition: c, originalObjects: [first], newObject: added,
            apply: false, expectedFingerprint: nil, reread: { any }, write: { _ in throw Failure(text: "any-change duplicate wrote") })
        throw Failure(text: "any-change duplicate accepted")
    } catch CharacteristicEventAppend.Invalid.duplicate { }
    let unsupported = CharacteristicEventAppend.Snapshot(homeID: "home", triggerID: "trigger", events: [a,b], guards: guards, unsupported: ["unknown event"])
    do {
        _ = try await CharacteristicEventAppend.run(before: unsupported, addition: c, originalObjects: [first,second], newObject: added,
            apply: true, expectedFingerprint: unsupported.fingerprint(adding: c), reread: { unsupported }, write: { _ in throw Failure(text: "unsupported wrote") })
        throw Failure(text: "unsupported accepted")
    } catch CharacteristicEventAppend.Invalid.unsupported { }
    writes = 0
    let changed = CharacteristicEventAppend.Snapshot(homeID: "home", triggerID: "trigger", events: [a,b], guards: ["concurrent": "client"], unsupported: [])
    do {
        _ = try await CharacteristicEventAppend.run(before: before, addition: c, originalObjects: [first,second], newObject: added,
            apply: true, expectedFingerprint: fingerprint, reread: { changed }, write: { _ in writes += 1 })
        throw Failure(text: "concurrent pre-write change accepted")
    } catch CharacteristicEventAppend.Invalid.stale { }
    try expect(writes == 0, "concurrent pre-write edit wrote")
    for failReadback in [false,true] {
        current = before; writes = 0; var reads = 0
        let result = try await CharacteristicEventAppend.run(before: before, addition: c, originalObjects: [first,second], newObject: added,
            apply: true, expectedFingerprint: fingerprint, reread: {
                reads += 1
                if reads > 1 && failReadback { throw Failure(text: "lost readback") }
                return reads > 1 ? changed : before
            }, write: { _ in writes += 1 })
        try expect(result.status == "unverified" && writes == 1, "readback failure/mismatch succeeded or retried")
    }
    writes = 0
    let failed = try await CharacteristicEventAppend.run(before: before, addition: c, originalObjects: [first,second], newObject: added,
        apply: true, expectedFingerprint: fingerprint, reread: { before }, write: { _ in writes += 1; throw Failure(text: "callback error") })
    try expect(failed.status == "failed" && writes == 1 && failed.dictionary["verified"] as? Bool == false, "callback failure succeeded or retried")
    writes = 0
    let timedOut = try await CharacteristicEventAppend.run(before: before, addition: c, originalObjects: [first,second], newObject: added,
        apply: true, expectedFingerprint: fingerprint, reread: { before }, write: { _ in writes += 1; throw CharacteristicEventAppend.CallbackTimeout() })
    try expect(timedOut.status == "unverified" && writes == 1, "callback timeout was verified, retried or called failed")
    writes = 0
    var polls = 0, pauses = 0
    let settles = try await CharacteristicEventAppend.run(before: before, addition: c,
        originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
        unchangedReadbackRechecks: 3, pauseReadback: { pauses += 1 },
        reread: { polls += 1; return polls >= 4 ? expected : before },
        write: { _ in writes += 1 })
    try expect(settles.status == "verified" && writes == 1 && pauses == 2, "bounded readback did not settle or retried the write")
    writes = 0; polls = 0; pauses = 0
    let divergence = try await CharacteristicEventAppend.run(before: before, addition: c,
        originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
        unchangedReadbackRechecks: 3, pauseReadback: { pauses += 1 },
        reread: { polls += 1; return polls > 1 ? changed : before },
        write: { _ in writes += 1 })
    try expect(divergence.status == "unverified" && writes == 1 && pauses == 0 && !divergence.problems.isEmpty,
               "divergent readback should remain unverified and should not be polled")
    writes = 0; pauses = 0
    let exhausted = try await CharacteristicEventAppend.run(before: before, addition: c,
        originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
        unchangedReadbackRechecks: 9, pauseReadback: { pauses += 1 }, reread: { before },
        write: { _ in writes += 1 })
    try expect(exhausted.status == "unverified" && pauses == 3 && writes == 1, "readback wait was not bounded")
    // Shape observed in real HomeKit: the daemon assigns new IDs to all saved
    // events and reorders them. Only the post-write event comparison is semantic.
    let movedC = CharacteristicEventAppend.Event(id: "server-motion", signature: c.signature, characteristicID: c.characteristicID, value: c.value)
    let movedA = CharacteristicEventAppend.Event(id: "server-calendar", signature: a.signature, characteristicID: a.characteristicID, value: a.value)
    let movedB = CharacteristicEventAppend.Event(id: "server-prior-motion", signature: b.signature, characteristicID: b.characteristicID, value: b.value)
    let accepted = CharacteristicEventAppend.Snapshot(homeID: before.homeID, triggerID: before.triggerID,
        events: [movedC, movedA, movedB], guards: before.guards, unsupported: [])
    let wrongValue = CharacteristicEventAppend.Event(id: movedC.id, signature: c.signature,
        characteristicID: c.characteristicID, value: "number:0")
    let wrongTarget = CharacteristicEventAppend.Event(id: movedC.id, signature: c.signature,
        characteristicID: "not-the-proposed-sensor", value: c.value)
    let wrongTime = CharacteristicEventAppend.Event(id: movedA.id, signature: "calendar:13:30", characteristicID: nil, value: nil)
    let mutationCases: [(String, CharacteristicEventAppend.Snapshot, Bool)] = [
        ("daemon IDs/order", accepted, true),
        ("wrong event value", .init(homeID: before.homeID, triggerID: before.triggerID, events: [wrongValue,movedA,movedB], guards: before.guards, unsupported: []), false),
        ("wrong target", .init(homeID: before.homeID, triggerID: before.triggerID, events: [wrongTarget,movedA,movedB], guards: before.guards, unsupported: []), false),
        ("original schedule changed", .init(homeID: before.homeID, triggerID: before.triggerID, events: [movedC,wrongTime,movedB], guards: before.guards, unsupported: []), false),
        ("lost event and duplicate with same array size", .init(homeID: before.homeID, triggerID: before.triggerID, events: [movedC,movedA,movedA], guards: before.guards, unsupported: []), false),
        ("changed guard", .init(homeID: before.homeID, triggerID: before.triggerID, events: accepted.events, guards: ["changed":"condition"], unsupported: []), false),
        ("changed rule identity", .init(homeID: before.homeID, triggerID: "another-rule", events: accepted.events, guards: before.guards, unsupported: []), false),
    ]
    for (label, observed, shouldVerify) in mutationCases {
        writes = 0; polls = 0
        let result = try await CharacteristicEventAppend.run(before: before, addition: c,
            originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
            reread: { polls += 1; return polls == 1 ? before : observed }, write: { _ in writes += 1 })
        try expect((result.status == "verified") == shouldVerify && writes == 1, "semantic postwrite check: " + label)
    }
    writes = 0
    let prewriteChangedID = CharacteristicEventAppend.Snapshot(homeID: before.homeID, triggerID: before.triggerID,
        events: [movedA,b], guards: before.guards, unsupported: [])
    do {
        _ = try await CharacteristicEventAppend.run(before: before, addition: c,
            originalObjects: [first,second], newObject: added, apply: true, expectedFingerprint: fingerprint,
            reread: { prewriteChangedID }, write: { _ in writes += 1 })
        throw Failure(text: "semantic tolerance leaked into strict prewrite consent")
    } catch CharacteristicEventAppend.Invalid.stale { }
    try expect(writes == 0, "a changed prewrite event identity wrote")
    print("PASS append transaction including bounded readback and strict semantic preservation; no HomeKit")
}

private func verifyAppendValuesAndRequests() throws {
    struct Failure: Error {}
    func number(_ value: String, _ format: String, _ min: Double? = nil, _ max: Double? = nil, _ valid: [Double]? = nil) -> NSNumber? {
        CharacteristicEventAppend.value(value, format: format, minimum: min, maximum: max, valid: valid)
    }
    guard number("true","bool")?.doubleValue == 1, number("false","bool")?.doubleValue == 0,
          number("2","bool") == nil, number("yes","bool") == nil, number("", "float") == nil,
          number("nan","float") == nil, number("inf","float") == nil, number("1.5","uint8") == nil,
          number("-1","uint8") == nil, number("256","uint8") == nil,
          number("4","uint16",0,3) == nil, number("2","uint8",0,3,[0,1]) == nil,
          number("1.5","float",0,3)?.doubleValue == 1.5, number("foo","string") == nil else { throw Failure() }
    let args: [String: Any] = ["id":"rule", "accessory_id":"sensor", "characteristic":"motion_detected", "trigger_value":"true"]
    guard try CharacteristicEventAppend.Request(args).apply == false else { throw Failure() }
    for (key,bad) in [("apply",1 as Any), ("apply","true" as Any), ("trigger_value",NSNull()), ("trigger_value",""), ("service_index",true), ("service_index",1.5), ("fingerprint",NSNull())] {
        var invalid = args; invalid[key] = bad
        do { _ = try CharacteristicEventAppend.Request(invalid); throw Failure() }
        catch is Failure { throw Failure() } catch { }
    }
    var apply = args; apply["apply"] = true
    do { _ = try CharacteristicEventAppend.Request(apply); throw Failure() }
    catch is CharacteristicEventAppend.Invalid { }
    apply["fingerprint"] = "current"; apply["dry_run"] = true
    do { _ = try CharacteristicEventAppend.Request(apply); throw Failure() }
    catch is Failure { throw Failure() } catch { }
    print("PASS typed values and request validation; malformed/missing values, boolean apply and selectors fail closed")
}

private func verifyFloatTargets() throws {
    struct Failure: Error { let text: String }
    func expect(_ value: @autoclosure () -> Bool, _ text: String) throws {
        if !value() { throw Failure(text: text) }
    }
    func parse(_ text: String) -> NSNumber? {
        CharacteristicEventAppend.value(text, format: "float", minimum: nil, maximum: nil, valid: nil)
    }
    try expect(parse("1e308") == nil, "Double-finite Float overflow must fail")
    try expect(parse("1e39") == nil, "Float overflow must fail")
    try expect(parse("1e-80") == nil, "Nonzero Float underflow must fail")
    for value in ["1e-400", "-0.001E-400", "0x1p-2000"] {
        try expect(parse(value) == nil, "Double underflow must not become a zero trigger: \(value)")
        try expect(CharacteristicEventAppend.value(value, format: "uint8", minimum: nil, maximum: nil, valid: nil) == nil,
                   "Underflow must not become a zero integer trigger: \(value)")
    }
    for value in ["0", "-0.000e-400", "+0.0E-50", "0x0p-2000"] {
        try expect(parse(value)?.floatValue == 0, "An explicit zero must remain valid: \(value)")
    }
    try expect(parse("1e-40")?.floatValue != 0, "Representable subnormal must survive")
    guard let normalized = parse("0.1") else { throw Failure(text: "Normal Float target rejected") }
    try expect(normalized.doubleValue == Double(Float(0.1)), "Preview must normalize to HAP Float32")
    let floatValue = CharacteristicEventAppend.canonicalNumber(normalized, format: "float")
    let doubleValue = CharacteristicEventAppend.canonicalNumber(NSNumber(value: 0.1), format: "float")
    try expect(floatValue != nil && floatValue == doubleValue, "Float/double proxy canonicalization differs")
    try expect(CharacteristicEventAppend.canonicalNumber(NSNumber(value: -0.0), format: "float") == CharacteristicEventAppend.canonicalNumber(NSNumber(value: 0.0), format: "float"), "Signed zero must canonicalize equally")
    try expect(CharacteristicEventAppend.canonicalNumber(NSNumber(value: Double.infinity), format: "float") == nil, "Infinite canonical target accepted")
    try expect(CharacteristicEventAppend.canonicalNumber(NSNumber(value: Double.nan), format: nil) == nil, "NaN canonical target accepted")
    try expect(CharacteristicEventAppend.canonicalNumber(NSNumber(value: 1e308), format: nil) == nil, "Unrepresentable decimal canonical target accepted")
    let snapshot = CharacteristicEventAppend.Snapshot(homeID: "h", triggerID: "t", events: [], guards: ["predicate":"opaque"], unsupported: [])
    let a = CharacteristicEventAppend.Event(id: "preview-random-uuid", signature: "characteristic", characteristicID: "float-char", value: floatValue)
    let b = CharacteristicEventAppend.Event(id: "apply-random-uuid", signature: "characteristic", characteristicID: "float-char", value: doubleValue)
    try expect(snapshot.fingerprint(adding: a) == snapshot.fingerprint(adding: b), "Same normalized proposal must keep fingerprint across new event UUIDs")
    print("PASS persisted Float32 overflow/underflow/rounding, float-vs-double/zero canonicalization, nonfinite decimal and proposal fingerprint regressions")
}

@MainActor private func verifyCallbackRace() async throws {
    struct Failure: Error {}
    var timeout: (@Sendable () -> Void)?
    var late: (@Sendable (Error?) -> Void)?
    var starts = 0
    do {
        try await CharacteristicEventAppend.awaitCallback(begin: { completion in
            starts += 1; late = completion; timeout!()
        }, scheduleTimeout: { timeout = $0 })
        throw Failure()
    } catch is CharacteristicEventAppend.CallbackTimeout { }
    // Both a late success and duplicate error callback are ignored, without a
    // second continuation resume or a second request.
    late?(nil); late?(Failure())
    guard starts == 1 else { throw Failure() }
    try await CharacteristicEventAppend.awaitCallback(begin: { completion in
        starts += 1; completion(nil); completion(Failure()); timeout!()
    }, scheduleTimeout: { timeout = $0 })
    guard starts == 2 else { throw Failure() }
    print("PASS deterministic no-callback deadline, late/duplicate callbacks, success before deadline; exactly one completion")
}

#if EVENT_APPEND_STANDALONE
@main struct EventAppendTestRunner {
    @MainActor static func main() async throws {
        try await verifyCharacteristicEventAppend()
        try verifyAppendValuesAndRequests()
        try verifyFloatTargets()
        try await verifyCallbackRace()
    }
}
#else
@MainActor final class CharacteristicEventAppendTests: XCTestCase {
    func testOneShotAppendTransaction() async throws { try await verifyCharacteristicEventAppend() }
    func testTypedValuesAndWireRequests() throws { try verifyAppendValuesAndRequests() }
    func testMissingAndLateCallbackRace() async throws { try await verifyCallbackRace() }
    func testFiniteFloatTargetsAndCanonicalFingerprint() throws { try verifyFloatTargets() }
    func testReadOnlyHTTPRejectsAppendEvent() {
        XCTAssertFalse(HTTPToolPolicy.readOnly.allowsCall(name: "homekit_automations", arguments: ["action":"append_event", "apply":true]))
    }
}
#endif
