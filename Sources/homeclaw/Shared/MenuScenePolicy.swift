import Foundation

/// Menu-only eligibility under Selected Only. Scene execution is all-or-nothing;
/// allowing just some actions would still execute the entire HomeKit action set.
enum MenuScenePolicy {
    static func disabledReason(actionAccessoryIDs: [String?], allowedIDs: Set<String>?) -> String? {
        guard !actionAccessoryIDs.isEmpty else { return nil }
        guard let allowedIDs else {
            return "Accessory selection is unavailable in Selected Only."
        }
        guard actionAccessoryIDs.allSatisfy({ $0 != nil }) else {
            return "Some scene accessories could not be identified in Selected Only."
        }
        guard actionAccessoryIDs.allSatisfy({ $0.map(allowedIDs.contains) == true }) else {
            return "This scene includes accessories outside Selected Only."
        }
        return nil
    }
}
