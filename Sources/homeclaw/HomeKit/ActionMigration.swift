import Foundation

/// Planning logic for `automations migrate-actions` (issue #120): move the write
/// actions an accessory carries in automation action sets onto its replacement(s).
///
/// Everything here works on plain values so it can be unit-tested without
/// HomeKit, whose objects have no public initializers. `HomeKitManager` snapshots
/// the live home into these types, asks for a plan, and (with `--apply`) performs
/// only the writes this plan marks `supported`.
///
/// The hard boundary: action sets owned by an automation (hidden, excluded from
/// `home.actionSets`, reachable only through `trigger.actionSets`) cannot be
/// persistently mutated by third-party apps. The HomeKit daemon requires the
/// Apple-only `com.apple.homekit.private-spi-access` entitlement (see
/// docs/PRIVATE_API.md). Those sets are always `unsupported` and get manual
/// Apple Home steps instead of writes.
enum ActionMigration {
    static let hiddenReason = "hidden_action_set_requires_private_spi"

    // MARK: - Snapshot inputs

    struct Characteristic: Equatable, Sendable {
        let id: String
        let type: String
        let name: String
        let writable: Bool
    }

    struct Service: Equatable, Sendable {
        let id: String
        let name: String
        let type: String
        let characteristics: [Characteristic]
        /// ServiceLabelIndex (the gang or button number), when the accessory has one.
        var index: Int? = nil
    }

    struct Accessory: Equatable, Sendable {
        let id: String
        let name: String
        let room: String?
        let services: [Service]
    }

    /// The accessory being replaced. After a physical swap it may already be gone
    /// from the home, in which case only its UUID is known.
    struct OldAccessory: Equatable, Sendable {
        let id: String
        let name: String?
        let room: String?
        let present: Bool
    }

    /// A characteristic target value, kept typed so plans, verification and JSON
    /// output agree on what a scene sets.
    enum Value: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)

        /// Convert a HomeKit target value (an `NSCopying`, in practice `NSNumber`
        /// or `NSString`). JSON booleans and HomeKit bools bridge as CFBoolean.
        init(any raw: Any) {
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                } else if CFNumberIsFloatType(number as CFNumber) {
                    let d = number.doubleValue
                    self = d.rounded() == d && abs(d) < 1e15 ? .int(Int(d)) : .double(d)
                } else {
                    self = .int(number.intValue)
                }
            } else if let string = raw as? String {
                self = .string(string)
            } else {
                self = .string(String(describing: raw))
            }
        }

        /// Parse a loosely typed string (demo fixtures and inline action rows).
        init(parsing raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            switch trimmed.lowercased() {
            case "true": self = .bool(true); return
            case "false": self = .bool(false); return
            default: break
            }
            if let i = Int(trimmed) { self = .int(i) }
            else if let d = Double(trimmed) { self = .double(d) }
            else { self = .string(trimmed) }
        }

        var numeric: Double? {
            switch self {
            case .bool(let b): return b ? 1 : 0
            case .int(let i): return Double(i)
            case .double(let d): return d
            case .string: return nil
            }
        }

        /// Value equality as HomeKit sees it: `true`, `1` and `1.0` are the same
        /// target for a power characteristic, so compare numerically when both
        /// sides are numeric.
        func matches(_ other: Value) -> Bool {
            if let a = numeric, let b = other.numeric { return abs(a - b) < 1e-9 }
            return self == other
        }

        var jsonValue: Any {
            switch self {
            case .bool(let b): return b
            case .int(let i): return i
            case .double(let d): return d
            case .string(let s): return s
            }
        }

        var display: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .string(let s): return s
            }
        }
    }

    /// One characteristic write action in an action set.
    struct ActionRow: Equatable, Sendable {
        let actionID: String
        let accessoryID: String
        let accessoryName: String
        let room: String?
        let serviceID: String?
        let serviceName: String?
        let serviceType: String?
        let characteristicID: String
        let characteristicType: String
        let characteristicName: String
        let value: Value
    }

    struct TriggerRef: Equatable, Sendable {
        let id: String
        let name: String
    }

    struct ActionSetSnapshot: Equatable, Sendable {
        let id: String
        let name: String
        /// Present in `home.actionSets` (false means automation-owned and hidden).
        let visible: Bool
        let rows: [ActionRow]
        /// Actions that are not characteristic writes. Never touched; counted so
        /// verification can prove they survived.
        let nonWriteActionCount: Int
        /// Every automation that references this set.
        let usedBy: [TriggerRef]
    }

    struct AutomationSnapshot: Equatable, Sendable {
        let id: String
        let name: String
        let enabled: Bool
        let triggerType: String
        let triggerSummary: String
        /// The automation's trigger event watches the old accessory. Reported, never
        /// changed: this command does not touch triggers.
        let triggerUsesOldAccessory: Bool
        let actionSets: [ActionSetSnapshot]
    }

    // MARK: - Plan output

    enum Classification: String, Sendable {
        case visibleScene = "visible_scene"
        case hidden
    }

    enum Status: String, Sendable {
        case supported
        case unsupported
        case blocked
    }

    enum IssueKind: String, Sendable {
        /// A new accessory has no service carrying the characteristic.
        case missingCharacteristic = "missing_characteristic"
        /// The matching characteristic exists but is read-only.
        case notWritable = "not_writable"
        /// Several services on a new accessory carry the characteristic; a service
        /// selector is needed (#87).
        case ambiguousService = "ambiguous_service"
        /// No new accessory can receive the characteristic, so migrating would
        /// silently drop it.
        case unmapped = "no_replacement_characteristic"
        /// Two old actions map onto the same new characteristic with different values.
        case conflictingSources = "conflicting_sources"
        /// The set already writes the target characteristic with a different value.
        case conflictsWithExisting = "conflicts_with_existing_action"
        /// The set already writes the target characteristic with the same value.
        case alreadyPresent = "already_present"
    }

    struct ServiceRef: Equatable, Sendable {
        let id: String
        let name: String
        let type: String
        var index: Int? = nil
    }

    struct Issue: Equatable, Sendable {
        let kind: IssueKind
        let blocking: Bool
        let characteristicName: String
        let characteristicType: String
        let oldActionID: String?
        let newAccessoryID: String?
        let newAccessoryName: String?
        let candidates: [ServiceRef]
        let detail: String
    }

    struct Addition: Equatable, Sendable {
        let sourceActionID: String
        let accessoryID: String
        let accessoryName: String
        let room: String?
        let serviceID: String
        let serviceName: String
        let serviceType: String
        /// The matched service's type differs from the old action's service type
        /// (for example an outlet replaced by a switch).
        let serviceTypeChanged: Bool
        let characteristicID: String
        let characteristicType: String
        let characteristicName: String
        let value: Value
    }

    /// One characteristic write the set should contain after migration.
    struct ExpectedAction: Equatable, Sendable {
        let characteristicID: String
        let value: Value
    }

    struct ManualStep: Equatable, Sendable {
        let step: Int
        let action: String
        let fields: [String: String]
        let text: String
    }

    struct SetPlan: Equatable, Sendable {
        let actionSetID: String
        let name: String
        let classification: Classification
        let status: Status
        let reason: String?
        let rollback: [ActionRow]
        let nonWriteActionCount: Int
        let removals: [ActionRow]
        let additions: [Addition]
        let issues: [Issue]
        /// Other automations using this set (visible scenes only matter: editing a
        /// visible scene changes every automation and scene tile that uses it).
        let sharedWith: [TriggerRef]
        let expected: [ExpectedAction]
        let manualSteps: [ManualStep]
    }

    struct AutomationPlan: Equatable, Sendable {
        let automation: AutomationSnapshot
        let sets: [SetPlan]
        /// The automation's trigger watches the old accessory but none of its
        /// action sets write to it. Nothing to migrate; listed so the user sees
        /// which triggers will stop firing once the old accessory is removed.
        var triggerOnly: Bool { sets.isEmpty }
    }

    // MARK: - Old accessory resolution

    /// What the accessory lookup found for the `old` side of a replacement.
    struct LookupHit: Equatable, Sendable {
        let id: String
        let name: String
        let room: String?
        /// Visible under the accessory filter.
        let allowed: Bool
    }

    enum OldResolution: Equatable, Sendable {
        case resolved(OldAccessory)
        /// The lookup found an accessory the filter hides. Treated exactly like
        /// not found, as every other command does, and never as "already removed".
        case restricted
        case notFound
    }

    /// Resolve the accessory being replaced. A filtered accessory is rejected; the
    /// raw-UUID "no longer in the home" fallback applies only when the lookup
    /// found nothing at all.
    static func resolveOld(query: String, hit: LookupHit?) -> OldResolution {
        if let hit {
            guard hit.allowed else { return .restricted }
            return .resolved(OldAccessory(id: hit.id, name: hit.name, room: hit.room, present: true))
        }
        guard let uuid = UUID(uuidString: query.trimmingCharacters(in: .whitespaces)) else { return .notFound }
        return .resolved(OldAccessory(id: uuid.uuidString, name: nil, room: nil, present: false))
    }

    // MARK: - Planning

    static func isOld(_ row: ActionRow, _ oldID: String) -> Bool {
        row.accessoryID.caseInsensitiveCompare(oldID) == .orderedSame
    }

    /// Plan every automation that writes to the old accessory. Automations with no
    /// such actions are left out.
    static func plan(
        automations: [AutomationSnapshot], old: OldAccessory, replacements: [Accessory]
    ) -> [AutomationPlan] {
        automations.compactMap { automation in
            let sets = automation.actionSets.compactMap {
                plan(set: $0, automation: automation, old: old, replacements: replacements)
            }
            // Keep trigger-only dependencies (a motion sensor that fires a light
            // automation) so the report shows which triggers will break.
            guard !sets.isEmpty || automation.triggerUsesOldAccessory else { return nil }
            return AutomationPlan(automation: automation, sets: sets)
        }
    }

    /// Plan one action set, or nil when it has no actions on the old accessory.
    static func plan(
        set: ActionSetSnapshot, automation: AutomationSnapshot, old: OldAccessory, replacements: [Accessory]
    ) -> SetPlan? {
        let removals = set.rows.filter { isOld($0, old.id) }
        guard !removals.isEmpty else { return nil }
        let kept = set.rows.filter { !isOld($0, old.id) }

        var issues: [Issue] = []
        var candidates: [Addition] = []

        for row in removals {
            var producedAny = false
            var ambiguous = false
            for accessory in replacements {
                switch match(row, on: accessory) {
                case .matched(let addition):
                    candidates.append(addition)
                    producedAny = true
                case .missing:
                    issues.append(Issue(
                        kind: .missingCharacteristic, blocking: false,
                        characteristicName: row.characteristicName, characteristicType: row.characteristicType,
                        oldActionID: row.actionID, newAccessoryID: accessory.id, newAccessoryName: accessory.name,
                        candidates: [],
                        detail: "\(accessory.name) has no \(row.characteristicName) characteristic"))
                case .notWritable(let service):
                    issues.append(Issue(
                        kind: .notWritable, blocking: false,
                        characteristicName: row.characteristicName, characteristicType: row.characteristicType,
                        oldActionID: row.actionID, newAccessoryID: accessory.id, newAccessoryName: accessory.name,
                        candidates: [service],
                        detail: "\(accessory.name)'s \(row.characteristicName) on \(service.name) is read-only"))
                case .ambiguous(let services):
                    ambiguous = true
                    issues.append(Issue(
                        kind: .ambiguousService, blocking: true,
                        characteristicName: row.characteristicName, characteristicType: row.characteristicType,
                        oldActionID: row.actionID, newAccessoryID: accessory.id, newAccessoryName: accessory.name,
                        candidates: services,
                        detail: "\(accessory.name) has \(services.count) services with \(row.characteristicName) ("
                            + services.map(\.name).joined(separator: ", ")
                            + "); a service selector (service_name, service_id or service_index) is needed to pick one"))
                }
            }
            if !producedAny && !ambiguous {
                let names = replacements.map(\.name).joined(separator: ", ")
                issues.append(Issue(
                    kind: .unmapped, blocking: true,
                    characteristicName: row.characteristicName, characteristicType: row.characteristicType,
                    oldActionID: row.actionID, newAccessoryID: nil, newAccessoryName: nil, candidates: [],
                    detail: "No replacement (\(names)) can take \(row.characteristicName) = \(row.value.display); "
                        + "migrating would drop it"))
            }
        }

        // Two old actions landing on the same new characteristic: identical values
        // merge into one action, different values cannot both be honoured.
        var additions: [Addition] = []
        var conflicted = Set<String>()
        for addition in candidates {
            if let existing = additions.first(where: { $0.characteristicID == addition.characteristicID }) {
                if !existing.value.matches(addition.value), conflicted.insert(addition.characteristicID).inserted {
                    issues.append(Issue(
                        kind: .conflictingSources, blocking: true,
                        characteristicName: addition.characteristicName, characteristicType: addition.characteristicType,
                        oldActionID: addition.sourceActionID, newAccessoryID: addition.accessoryID,
                        newAccessoryName: addition.accessoryName, candidates: [],
                        detail: "Several old actions map to \(addition.accessoryName) \(addition.characteristicName) "
                            + "with different values (\(existing.value.display), \(addition.value.display))"))
                }
                continue
            }
            additions.append(addition)
        }

        // The set may already write the target characteristic (the new accessory
        // was added by hand, or this is a rerun).
        additions = additions.filter { addition in
            guard let existing = kept.first(where: { $0.characteristicID == addition.characteristicID }) else {
                return true
            }
            let same = existing.value.matches(addition.value)
            issues.append(Issue(
                kind: same ? .alreadyPresent : .conflictsWithExisting, blocking: !same,
                characteristicName: addition.characteristicName, characteristicType: addition.characteristicType,
                oldActionID: addition.sourceActionID, newAccessoryID: addition.accessoryID,
                newAccessoryName: addition.accessoryName, candidates: [],
                detail: same
                    ? "\(addition.accessoryName) \(addition.characteristicName) is already set to \(existing.value.display)"
                    : "The set already sets \(addition.accessoryName) \(addition.characteristicName) to "
                        + "\(existing.value.display), not \(addition.value.display)"))
            return false
        }

        let classification: Classification = set.visible ? .visibleScene : .hidden
        let status: Status
        let reason: String?
        if !set.visible {
            status = .unsupported
            reason = hiddenReason
        } else if issues.contains(where: \.blocking) {
            status = .blocked
            reason = issues.first(where: \.blocking)?.kind.rawValue
        } else {
            status = .supported
            reason = nil
        }

        let expected = kept.map { ExpectedAction(characteristicID: $0.characteristicID, value: $0.value) }
            + additions.map { ExpectedAction(characteristicID: $0.characteristicID, value: $0.value) }

        let sharedWith = set.usedBy.filter { $0.id.caseInsensitiveCompare(automation.id) != .orderedSame }
        let steps = set.visible
            ? []
            : manualSteps(automation: automation, old: old, removals: removals, additions: additions,
                          replacements: replacements, issues: issues)

        return SetPlan(
            actionSetID: set.id, name: set.name, classification: classification, status: status, reason: reason,
            rollback: set.rows, nonWriteActionCount: set.nonWriteActionCount,
            removals: removals, additions: additions, issues: issues,
            sharedWith: sharedWith, expected: expected, manualSteps: steps)
    }

    enum Match: Equatable {
        case matched(Addition)
        case missing
        case notWritable(ServiceRef)
        case ambiguous([ServiceRef])
    }

    /// Find the characteristic on `accessory` that should receive `row`, matched by
    /// characteristic type. A service of the same type as the old action's wins;
    /// otherwise a single carrier of any type is accepted (flagged as a service
    /// type change). Several equally good carriers are ambiguous, never "first".
    static func match(_ row: ActionRow, on accessory: Accessory) -> Match {
        let carriers: [(Service, Characteristic)] = accessory.services.compactMap { service in
            service.characteristics.first(where: { $0.type == row.characteristicType }).map { (service, $0) }
        }
        guard !carriers.isEmpty else { return .missing }

        let sameType = carriers.filter { row.serviceType != nil && $0.0.type == row.serviceType }
        let chosen: (Service, Characteristic)
        if sameType.count == 1 {
            chosen = sameType[0]
        } else if sameType.count > 1 {
            return .ambiguous(sameType.map { ref($0.0) })
        } else if carriers.count == 1 {
            chosen = carriers[0]
        } else {
            return .ambiguous(carriers.map { ref($0.0) })
        }

        let (service, characteristic) = chosen
        guard characteristic.writable else { return .notWritable(ref(service)) }
        return .matched(Addition(
            sourceActionID: row.actionID,
            accessoryID: accessory.id, accessoryName: accessory.name, room: accessory.room,
            serviceID: service.id, serviceName: service.name, serviceType: service.type,
            serviceTypeChanged: row.serviceType != nil && row.serviceType != service.type,
            characteristicID: characteristic.id, characteristicType: characteristic.type,
            characteristicName: characteristic.name, value: row.value))
    }

    private static func ref(_ service: Service) -> ServiceRef {
        ServiceRef(id: service.id, name: service.name, type: service.type, index: service.index)
    }

    // MARK: - Manual Apple Home steps

    /// Machine-readable steps a client can render as Apple Home instructions for a
    /// hidden set this app is not allowed to write.
    static func manualSteps(
        automation: AutomationSnapshot, old: OldAccessory, removals: [ActionRow], additions: [Addition],
        replacements: [Accessory], issues: [Issue]
    ) -> [ManualStep] {
        var steps: [(String, [String: String], String)] = []
        steps.append(("open_automation",
                      ["automation_id": automation.id, "automation_name": automation.name,
                       "trigger_summary": automation.triggerSummary],
                      "In the Home app, open Automations and select '\(automation.name)' (\(automation.triggerSummary))."))
        let oldName = old.name ?? removals.first?.accessoryName ?? old.id
        steps.append(("remove_accessory", ["accessory_id": old.id, "accessory_name": oldName],
                      "Remove '\(oldName)' from the automation's accessories."))
        for accessory in replacements where additions.contains(where: { $0.accessoryID == accessory.id }) {
            var fields = ["accessory_id": accessory.id, "accessory_name": accessory.name]
            if let room = accessory.room { fields["room"] = room }
            steps.append(("add_accessory", fields,
                          "Add '\(accessory.name)'" + (accessory.room.map { " (\($0))" } ?? "") + "."))
        }
        for addition in additions {
            var fields = [
                "accessory_id": addition.accessoryID, "accessory_name": addition.accessoryName,
                "service_id": addition.serviceID, "service_name": addition.serviceName,
                "characteristic": addition.characteristicName, "value": addition.value.display,
            ]
            if let room = addition.room { fields["room"] = room }
            steps.append(("set_characteristic", fields,
                          "Set '\(addition.accessoryName)' \(addition.characteristicName) to \(addition.value.display)."))
        }
        for issue in issues where issue.blocking {
            steps.append(("review_issue", ["kind": issue.kind.rawValue, "characteristic": issue.characteristicName],
                          "Check by hand: \(issue.detail)."))
        }
        steps.append(("save", [:],
                      "Tap Done. Then rerun this command as a dry run: the automation should no longer appear."))
        return steps.enumerated().map { ManualStep(step: $0.offset + 1, action: $0.element.0,
                                                   fields: $0.element.1, text: $0.element.2) }
    }

    // MARK: - Apply selection and warnings

    /// The sets `--apply` writes: supported visible scenes, each once even when
    /// several automations share it. Hidden and blocked sets never get writes.
    static func setsToApply(_ plans: [AutomationPlan]) -> [SetPlan] {
        var seen = Set<String>()
        return plans.flatMap(\.sets).filter {
            $0.status == .supported && $0.classification == .visibleScene && seen.insert($0.actionSetID).inserted
        }
    }

    static func warnings(old: OldAccessory, plans: [AutomationPlan]) -> [String] {
        var warnings: [String] = []
        if !old.present {
            warnings.append("The old accessory \(old.id) is not in this home. HomeKit usually drops an accessory's "
                + "scene actions when it is removed, so migrate while the old accessory is still paired.")
        }
        if plans.contains(where: \.automation.triggerUsesOldAccessory) {
            warnings.append("Some automations are triggered by the old accessory. This command never changes triggers; "
                + "recreate those automations in the Home app (see trigger_uses_old_accessory; trigger_only ones have "
                + "no actions to migrate).")
        }
        if plans.contains(where: { $0.sets.contains { $0.classification == .visibleScene && !$0.sharedWith.isEmpty } }) {
            warnings.append("Some visible scenes are shared with other automations. Editing one changes every automation "
                + "and scene tile that uses it (see shared_with).")
        }
        if plans.contains(where: { $0.sets.contains { $0.classification == .hidden } }) {
            warnings.append("Automation-owned hidden action sets cannot be written by third-party apps (Apple's private "
                + "SPI entitlement is required). Follow their manual_steps in the Home app.")
        }
        return warnings
    }

    // MARK: - Verification

    struct Verification: Equatable, Sendable {
        let missing: [ExpectedAction]
        let unexpected: [ExpectedAction]
        var verified: Bool { missing.isEmpty && unexpected.isEmpty }
    }

    /// Compare a fresh read of a set's write actions against the plan's expected
    /// contents, as multisets keyed by characteristic and value.
    static func verify(expected: [ExpectedAction], actual: [ExpectedAction]) -> Verification {
        var remaining = actual
        var missing: [ExpectedAction] = []
        for want in expected {
            if let index = remaining.firstIndex(where: {
                $0.characteristicID.caseInsensitiveCompare(want.characteristicID) == .orderedSame
                    && $0.value.matches(want.value)
            }) {
                remaining.remove(at: index)
            } else {
                missing.append(want)
            }
        }
        return Verification(missing: missing, unexpected: remaining)
    }

    // MARK: - Apply results

    enum ApplyStatus: String, Sendable {
        case applied
        case failed
        case skipped
    }

    struct ApplyResult: Equatable, Sendable {
        let status: ApplyStatus
        let addedActions: [String]
        let removedActionIDs: [String]
        let verification: Verification?
        let error: String?
        let note: String?
    }

    // MARK: - JSON rendering

    static func json(_ row: ActionRow) -> [String: Any] {
        var dict: [String: Any] = [
            "action_id": row.actionID,
            "accessory": row.accessoryName,
            "accessory_id": row.accessoryID,
            "characteristic": row.characteristicName,
            "characteristic_type": row.characteristicType,
            "characteristic_id": row.characteristicID,
            "value": row.value.jsonValue,
        ]
        if let room = row.room { dict["room"] = room }
        if let id = row.serviceID { dict["service_id"] = id }
        if let name = row.serviceName { dict["service_name"] = name }
        if let type = row.serviceType { dict["service_type"] = type }
        return dict
    }

    static func json(_ addition: Addition) -> [String: Any] {
        var dict: [String: Any] = [
            "source_action_id": addition.sourceActionID,
            "accessory": addition.accessoryName,
            "accessory_id": addition.accessoryID,
            "service_id": addition.serviceID,
            "service_name": addition.serviceName,
            "service_type": addition.serviceType,
            "characteristic": addition.characteristicName,
            "characteristic_type": addition.characteristicType,
            "characteristic_id": addition.characteristicID,
            "value": addition.value.jsonValue,
        ]
        if addition.serviceTypeChanged { dict["service_type_changed"] = true }
        if let room = addition.room { dict["room"] = room }
        return dict
    }

    static func json(_ issue: Issue) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": issue.kind.rawValue,
            "blocking": issue.blocking,
            "characteristic": issue.characteristicName,
            "characteristic_type": issue.characteristicType,
            "detail": issue.detail,
        ]
        if let id = issue.oldActionID { dict["old_action_id"] = id }
        if let id = issue.newAccessoryID { dict["accessory_id"] = id }
        if let name = issue.newAccessoryName { dict["accessory"] = name }
        if !issue.candidates.isEmpty {
            // Each candidate carries the selector fields action rows accept, so the
            // user can target one service with update-scene.
            dict["candidates"] = issue.candidates.map { ref -> [String: Any] in
                var c: [String: Any] = ["service_id": ref.id, "service_name": ref.name, "service_type": ref.type]
                if let index = ref.index { c["service_index"] = index }
                return c
            }
        }
        return dict
    }

    static func json(_ ref: TriggerRef) -> [String: Any] { ["id": ref.id, "name": ref.name] }

    static func json(_ expected: ExpectedAction) -> [String: Any] {
        ["characteristic_id": expected.characteristicID, "value": expected.value.jsonValue]
    }

    /// Flat characteristic summary of what the old accessory did in this set, in the
    /// shape the issue proposed (`{"power": true, "brightness": 50}`). A name set to
    /// different values on several services becomes an array.
    static func characteristicSummary(_ rows: [ActionRow]) -> [String: Any] {
        var grouped: [String: [Value]] = [:]
        var order: [String] = []
        for row in rows {
            if grouped[row.characteristicName] == nil { order.append(row.characteristicName) }
            var values = grouped[row.characteristicName] ?? []
            if !values.contains(where: { $0.matches(row.value) }) { values.append(row.value) }
            grouped[row.characteristicName] = values
        }
        var out: [String: Any] = [:]
        for name in order {
            let values = grouped[name] ?? []
            out[name] = values.count == 1 ? values[0].jsonValue : values.map(\.jsonValue)
        }
        return out
    }

    static func json(_ plan: SetPlan, automation: AutomationSnapshot, apply: ApplyResult?) -> [String: Any] {
        var dict: [String: Any] = [
            "id": plan.actionSetID,
            "name": plan.name,
            "classification": plan.classification.rawValue,
            "status": plan.status.rawValue,
            "rollback": [
                "action_set_id": plan.actionSetID,
                "actions": plan.rollback.map(json),
                "non_write_action_count": plan.nonWriteActionCount,
            ] as [String: Any],
            "removals": plan.removals.map(json),
            "additions": plan.additions.map(json),
            "issues": plan.issues.map(json),
            "expected_actions": plan.expected.map(json),
        ]
        if let reason = plan.reason { dict["reason"] = reason }
        switch plan.classification {
        case .visibleScene:
            dict["shared_with"] = plan.sharedWith.map(json)
            dict["scene_tile"] = true
        case .hidden:
            // The issue's suggested fallback shape, alongside the full rows.
            dict["automation"] = ["uuid": automation.id, "name": automation.name]
            var removeIDs: [String] = []
            for row in plan.removals where !removeIDs.contains(row.accessoryID) { removeIDs.append(row.accessoryID) }
            var addIDs: [String] = []
            for addition in plan.additions where !addIDs.contains(addition.accessoryID) { addIDs.append(addition.accessoryID) }
            dict["remove_accessories"] = removeIDs
            dict["add_accessories"] = addIDs
            dict["characteristics"] = characteristicSummary(plan.removals)
            dict["manual_steps"] = plan.manualSteps.map { step -> [String: Any] in
                var s: [String: Any] = ["step": step.step, "action": step.action, "text": step.text]
                for (k, v) in step.fields { s[k] = v }
                return s
            }
        }
        if let apply {
            var a: [String: Any] = [
                "status": apply.status.rawValue,
                "added": apply.addedActions,
                "removed_action_ids": apply.removedActionIDs,
            ]
            if let v = apply.verification {
                a["verification"] = [
                    "verified": v.verified,
                    "missing": v.missing.map(json),
                    "unexpected": v.unexpected.map(json),
                ] as [String: Any]
            }
            if let e = apply.error { a["error"] = e }
            if let n = apply.note { a["note"] = n }
            dict["apply"] = a
        }
        return dict
    }

    /// Full command result. `applyResults` is keyed by action set id; nil for a dry run.
    static func report(
        home: String,
        old: OldAccessory,
        replacements: [Accessory],
        automationFilter: String?,
        plans: [AutomationPlan],
        unattachedScenes: [(id: String, name: String, actionCount: Int)],
        applyResults: [String: ApplyResult]?,
        warnings: [String]
    ) -> [String: Any] {
        var oldDict: [String: Any] = ["id": old.id, "present": old.present]
        if let name = old.name { oldDict["name"] = name }
        if let room = old.room { oldDict["room"] = room }

        // Count each distinct action set once, even when several automations share it.
        var seen = Set<String>()
        var counts: [Status: Int] = [:]
        for plan in plans { for set in plan.sets where seen.insert(set.actionSetID).inserted { counts[set.status, default: 0] += 1 } }

        var summary: [String: Any] = [
            "automations": plans.count,
            "trigger_only": plans.filter(\.triggerOnly).count,
            "action_sets": seen.count,
            "supported": counts[.supported] ?? 0,
            "unsupported": counts[.unsupported] ?? 0,
            "blocked": counts[.blocked] ?? 0,
        ]
        if let applyResults {
            summary["applied"] = applyResults.values.filter { $0.status == .applied }.count
            summary["failed"] = applyResults.values.filter { $0.status == .failed }.count
            summary["verified"] = applyResults.values.filter { $0.verification?.verified == true }.count
        }

        var result: [String: Any] = [
            "mode": applyResults == nil ? "dry_run" : "apply",
            "dry_run": applyResults == nil,
            "home": home,
            "old_accessory": oldDict,
            "new_accessories": replacements.map { acc -> [String: Any] in
                var d: [String: Any] = ["id": acc.id, "name": acc.name]
                if let room = acc.room { d["room"] = room }
                return d
            },
            "automations": plans.map { plan -> [String: Any] in
                [
                    "id": plan.automation.id,
                    "name": plan.automation.name,
                    "enabled": plan.automation.enabled,
                    "trigger_type": plan.automation.triggerType,
                    "trigger_summary": plan.automation.triggerSummary,
                    "trigger_uses_old_accessory": plan.automation.triggerUsesOldAccessory,
                    "trigger_only": plan.triggerOnly,
                    "action_sets": plan.sets.map { json($0, automation: plan.automation, apply: applyResults?[$0.actionSetID]) },
                ]
            },
            "unattached_scenes": unattachedScenes.map { ["id": $0.id, "name": $0.name, "old_accessory_action_count": $0.actionCount] },
            "summary": summary,
            "warnings": warnings,
        ]
        if let automationFilter { result["automation_filter"] = automationFilter }
        return result
    }
}
