import CoreFoundation
import CryptoKit
import Foundation

/// One-shot characteristic event edit transaction. No HomeKit dependency: adapters supply the current
/// snapshot, original event objects and the one public updateEvents operation.
enum CharacteristicEventAppend {
    struct CallbackTimeout: Error, LocalizedError {
        var errorDescription: String? { "HomeKit callback deadline expired; the write may still apply later" }
    }

    private final class CallbackGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if completed { return false }
            completed = true; return true
        }
    }

    /// Injected scheduler makes missing and late callbacks deterministic in tests.
    @MainActor static func awaitCallback(
        begin: (@escaping @Sendable (Error?) -> Void) -> Void,
        scheduleTimeout: (@escaping @Sendable () -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CallbackGate()
            scheduleTimeout {
                if gate.claim() { continuation.resume(throwing: CallbackTimeout()) }
            }
            begin { error in
                guard gate.claim() else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    struct Request {
        let id: String, accessoryID: String, characteristic: String, value: String
        let serviceName: String?, serviceID: String?, serviceIndex: Int?, homeID: String?, fingerprint: String?
        let apply: Bool
        let replacedEventID: UUID?

        init(_ args: [String: Any], retarget: Bool = false) throws {
            let verb = retarget ? "retarget-event" : "append-event"
            func text(_ key: String, required: Bool = false) throws -> String? {
                guard let raw = args[key] else {
                    if required { throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key) is required"]) }
                    return nil
                }
                guard let string = raw as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key) must be a non-empty string"])
                }
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if retarget {
                guard let raw = try text("event_id", required: true), let uuid = UUID(uuidString: raw) else {
                    throw Invalid.invalidEventID
                }
                replacedEventID = uuid
            } else {
                guard args["event_id"] == nil else { throw Invalid.unexpectedEventID }
                replacedEventID = nil
            }
            id = try text("id", required: true)!
            accessoryID = try text("accessory_id", required: true)!
            characteristic = try text("characteristic", required: true)!
            value = try text("trigger_value", required: true)!
            serviceName = try text("service_name"); serviceID = try text("service_id")
            homeID = try text("home_id"); fingerprint = try text("fingerprint")
            if let raw = args["apply"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "apply must be a JSON boolean"])
                }
                apply = number.boolValue
            } else { apply = false }
            if let raw = args["service_index"] {
                let integer: Int?
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                   number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 1, number.doubleValue <= Double(Int32.max) {
                    integer = number.intValue
                } else if let text = raw as? String { integer = Int(text) }
                else { integer = nil }
                guard let integer, integer > 0 else {
                    throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "service_index must be a positive integer"])
                }
                serviceIndex = integer
            } else { serviceIndex = nil }
            if let raw = args["dry_run"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "dry_run must be a JSON boolean"])
                }
                if apply && number.boolValue { throw NSError(domain: verb, code: 1, userInfo: [NSLocalizedDescriptionKey: "apply and dry_run cannot both be true"]) }
            }
            if apply, fingerprint == nil { throw Invalid.fingerprintRequired }
        }
    }

    struct Event: Codable, Equatable {
        let id: String
        let signature: String
        let characteristicID: String?
        let value: String?
    }

    /// HomeKit can regenerate event identifiers and reorder OR alternatives
    /// when persisting updateEvents. A multiset still detects drops, additions,
    /// changed targets/values and extra copies of any event.
    private struct EventMeaning: Hashable {
        let signature: String
        let characteristicID: String?
        let value: String?
        init(_ event: Event) {
            self.signature = event.signature
            self.characteristicID = event.characteristicID
            self.value = event.value
        }
    }

    private static func eventCounts(_ events: [Event]) -> [EventMeaning: Int] {
        events.reduce(into: [:]) { counts, event in
            counts[EventMeaning(event), default: 0] += 1
        }
    }

    struct Snapshot: Codable, Equatable {
        let homeID: String
        let triggerID: String
        let events: [Event]
        let guards: [String: String]
        let unsupported: [String]

        func fingerprint(adding event: Event? = nil, replacing eventID: UUID? = nil) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // All stored fields are strings/arrays; encoding cannot fail.
            var data = try! encoder.encode(self)
            if let event {
                // Bind consent to the exact proposed target/value, but not the
                // random UUID of a freshly constructed, not-yet-added event.
                data.append(try! encoder.encode([event.signature, event.characteristicID ?? "", event.value ?? ""]))
            }
            // Existing append fingerprints stay compatible. A retarget token is
            // distinct from append and from every other source event in this rule.
            if let eventID { data.append(try! encoder.encode(["retarget", eventID.uuidString])) }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Invalid: Error, LocalizedError {
        case duplicate, unsupported([String]), fingerprintRequired, stale
        case invalidEventID, unexpectedEventID, eventNotUnique, unsupportedSource, unchangedRetarget
        var errorDescription: String? {
            switch self {
            case .duplicate: "That characteristic/value event already exists; nothing was written."
            case .unsupported(let reasons): "Cannot safely fingerprint this automation: \(reasons.joined(separator: ", ")). Nothing was written."
            case .fingerprintRequired: "Apply requires the fingerprint returned by a fresh append-event preview."
            case .invalidEventID: "event_id must be a current event UUID from automations get."
            case .unexpectedEventID: "event_id is accepted only for retarget-event. Nothing was written."
            case .eventNotUnique: "event_id did not identify exactly one current trigger event. Run automations get again. Nothing was written."
            case .unsupportedSource: "Retargeting requires one explicit boolean/numeric characteristic trigger, not an any-change, non-characteristic, or duplicate trigger. Nothing was written."
            case .unchangedRetarget: "The replacement already matches the selected event. Nothing was written."
            case .stale: "The automation or device selection changed since preview. Preview again; nothing was written."
            }
        }
    }

    struct Outcome {
        let status: String
        let before: Snapshot
        let after: Snapshot?
        let fingerprint: String
        let problems: [String]
        var dictionary: [String: Any] {
            var result: [String: Any] = [
                "status": status, "verified": status == "verified", "dry_run": status == "preview",
                "fingerprint": fingerprint,
                "warning": "Events are OR alternatives evaluated against the existing predicate. HomeKit may change event IDs and order. HomeKit provides no compare-and-swap; another client can race this operation. Fingerprints are valid only in this app session.",
            ]
            if let after { result["observed_fingerprint"] = after.fingerprint() }
            if !problems.isEmpty { result["problems"] = problems }
            return result
        }
    }

    @MainActor
    static func run<Token>(
        before: Snapshot, addition: Event, originalObjects: [Token], newObject: Token,
        apply: Bool, expectedFingerprint: String?, replacing eventID: UUID? = nil,
        unchangedReadbackRechecks: Int = 0,
        pauseReadback: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
        reread: @MainActor () throws -> Snapshot,
        write: @MainActor ([Token]) async throws -> Void
    ) async throws -> Outcome {
        guard originalObjects.count == before.events.count else { throw Invalid.unsupported(["inconsistent event snapshot"]) }
        var planned = before.events
        var plannedObjects = originalObjects
        let sourceIndex = try eventID.map { try replacementIndex(in: before.events, id: $0) }
        if let sourceIndex, EventMeaning(before.events[sourceIndex]) == EventMeaning(addition) {
            throw Invalid.unchangedRetarget
        }
        guard !before.events.enumerated().contains(where: { index, event in
            index != sourceIndex && event.characteristicID == addition.characteristicID
                && (event.value == addition.value || event.value == "any_change")
        }) else { throw Invalid.duplicate }
        guard before.unsupported.isEmpty else { throw Invalid.unsupported(before.unsupported) }
        if let sourceIndex {
            planned[sourceIndex] = addition
            plannedObjects[sourceIndex] = newObject
        } else {
            planned.append(addition)
            plannedObjects.append(newObject)
        }
        let fingerprint = before.fingerprint(adding: addition, replacing: eventID)
        guard apply else { return Outcome(status: "preview", before: before, after: nil, fingerprint: fingerprint, problems: []) }
        guard let expectedFingerprint, !expectedFingerprint.isEmpty else { throw Invalid.fingerprintRequired }
        guard expectedFingerprint == fingerprint, try reread() == before else { throw Invalid.stale }
        // Reuse the exact original objects and order. Never reconstruct predicates,
        // action sets, recurrences or end events. Never retry or roll back this write.
        do { try await write(plannedObjects) }
        catch {
            return Outcome(status: error is CallbackTimeout ? "unverified" : "failed", before: before, after: try? reread(), fingerprint: fingerprint,
                           problems: ["updateEvents callback failed: \(error.localizedDescription). The operation may have applied; inspect before retrying."])
        }
        let after: Snapshot
        do {
            var observed = try reread()
            // A successful callback can precede readback visibility. Only wait while
            // the snapshot is *exactly* unchanged. A divergent snapshot is evidence
            // of a possible concurrent edit, not permission to keep retrying.
            for _ in 0..<min(3, max(0, unchangedReadbackRechecks)) where observed == before {
                try await pauseReadback()
                observed = try reread()
            }
            after = observed
        } catch {
            return Outcome(status: "unverified", before: before, after: nil, fingerprint: fingerprint,
                           problems: ["Readback failed: \(error.localizedDescription). Inspect before retrying."])
        }
        var reasons: [String] = []
        if after == before { reasons.append("HomeKit still returned the pre-write snapshot.") }
        else {
            if after.homeID != before.homeID || after.triggerID != before.triggerID { reasons.append("Home or automation identity changed.") }
            if after.guards != before.guards || after.unsupported != before.unsupported { reasons.append("Preserved guard or linked-action metadata changed.") }
            if eventCounts(after.events) != eventCounts(planned) {
                reasons.append("The stored event types, targets, values, or multiplicities differ from the plan.")
            }
        }
        let verified = reasons.isEmpty
        if !verified { reasons.append("No write retry or rollback was attempted.") }
        return Outcome(status: verified ? "verified" : "unverified", before: before, after: after,
                       fingerprint: fingerprint, problems: reasons)
    }

    static func replacementIndex(in events: [Event], id: UUID) throws -> Int {
        let matches = events.indices.filter { UUID(uuidString: events[$0].id) == id }
        guard matches.count == 1, let index = matches.first else { throw Invalid.eventNotUnique }
        let event = events[index]
        guard event.signature == "characteristic", event.characteristicID != nil,
              let value = event.value, value.hasPrefix("number:") || value.hasPrefix("float32:"),
              events.filter({ EventMeaning($0) == EventMeaning(event) }).count == 1 else {
            throw Invalid.unsupportedSource
        }
        return index
    }

    /// Float fingerprints use normalized HAP Float32 bits, so NSNumber float vs
    /// double proxy representations cannot turn the same 0.1 target into a mismatch.
    static func canonicalNumber(_ number: NSNumber, format: String?) -> String? {
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        if format == "float" {
            let single = Float(value)
            guard single.isFinite, value == 0 || single != 0 else { return nil }
            return "float32:" + String((single == 0 ? Float(0) : single).bitPattern)
        }
        let decimal = NSDecimalNumber(decimal: number.decimalValue)
        guard decimal != .notANumber, value == 0 || decimal != .zero else { return nil }
        return "number:" + decimal.stringValue
    }

    /// Strict explicit-value parser. Limits the first implementation to typed
    /// booleans/numbers with finite/range checks; arbitrary strings/data are deferred.
    static func value(_ raw: String, format: String?, minimum: Double?, maximum: Double?, valid: [Double]?) -> NSNumber? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let number: Double
        if format == "bool" {
            switch text.lowercased() {
            case "true", "1": number = 1
            case "false", "0": number = 0
            default: return nil
            }
        } else {
            guard let parsed = Double(text), parsed.isFinite else { return nil }
            if parsed == 0 {
                // Double also returns zero for nonzero inputs below its range.
                // Inspect the significand, not the exponent, to distinguish true zero.
                let unsigned = text.drop(while: { $0 == "+" || $0 == "-" })
                let isHex = unsigned.lowercased().hasPrefix("0x")
                let digits = unsigned.dropFirst(isHex ? 2 : 0)
                let delimiters = isHex ? "pP" : "eE"
                let significand = digits.prefix(while: { !delimiters.contains($0) })
                guard significand.allSatisfy({ $0 == "0" || $0 == "." }) else { return nil }
            }
            number = parsed
            switch format {
            case "uint8": guard (0...255).contains(number) && number.rounded() == number else { return nil }
            case "uint16": guard (0...65535).contains(number) && number.rounded() == number else { return nil }
            case "uint32": guard (0...4294967295).contains(number) && number.rounded() == number else { return nil }
            case "int": guard (-2147483648...2147483647).contains(number) && number.rounded() == number else { return nil }
            case "float": break
            default: return nil
            }
        }
        let normalized: Double
        if format == "float" {
            let single = Float(number)
            guard single.isFinite, number == 0 || single != 0 else { return nil }
            normalized = Double(single)
            func bound(_ value: Double) -> Double { Double(Float(value)) }
            guard minimum.map({ bound($0).isFinite && normalized >= bound($0) }) ?? true,
                  maximum.map({ bound($0).isFinite && normalized <= bound($0) }) ?? true,
                  valid.map({ $0.contains { bound($0) == normalized } }) ?? true else { return nil }
            return NSNumber(value: single == 0 ? Float(0) : single)
        }
        guard minimum.map({ number >= $0 }) ?? true, maximum.map({ number <= $0 }) ?? true,
              valid.map({ $0.contains(number) }) ?? true else { return nil }
        if format == "bool" { return NSNumber(value: number == 1) }
        return NSNumber(value: Int64(number))
    }
}
