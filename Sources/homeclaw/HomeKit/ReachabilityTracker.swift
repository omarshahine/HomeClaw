import Foundation

/// Remembers the last-known reachability of each accessory so a
/// `reachability_change` event is logged only when the value actually changes.
///
/// HomeKit can call `accessoryDidUpdateReachability(_:)` again without the
/// value flipping (for example after a hub reconnects), and a flapping Thread
/// node would otherwise flood the event log. Plain value type so it is
/// testable without `HMAccessory`, which has no public initializer.
struct ReachabilityTracker {
    private var lastKnown: [String: Bool] = [:]

    /// Records the current reachability without reporting a change. Only fills
    /// in accessories that have no known value yet, so a delegate callback that
    /// is still queued behind a homes refresh is not swallowed by the refresh.
    mutating func seed(accessoryID: String, reachable: Bool) {
        if lastKnown[accessoryID] == nil {
            lastKnown[accessoryID] = reachable
        }
    }

    /// Records a reachability observation from the delegate callback.
    /// Returns true when it differs from the last-known value, or when the
    /// accessory has never been seen (HomeKit only calls the delegate when it
    /// believes the value changed, so the first report is treated as real).
    mutating func update(accessoryID: String, reachable: Bool) -> Bool {
        let previous = lastKnown.updateValue(reachable, forKey: accessoryID)
        return previous != reachable
    }

    /// Last-known reachability, or nil if the accessory has not been seen.
    func lastKnownReachable(accessoryID: String) -> Bool? {
        lastKnown[accessoryID]
    }

    /// Drops accessories that are no longer in any home.
    mutating func retain(accessoryIDs: Set<String>) {
        lastKnown = lastKnown.filter { accessoryIDs.contains($0.key) }
    }
}
