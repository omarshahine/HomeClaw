import XCTest
@testable import HomeClaw

final class StreamableHTTPSessionStoreTests: XCTestCase {
    func testCreateGetTouchAndRemoveLifecycle() async {
        let store = StreamableHTTPSessionStore(ttl: 60)
        let id = await store.create()
        XCTAssertFalse(id.isEmpty)
        let found = await store.get(id); XCTAssertNotNil(found)
        let touched = await store.touch(id); XCTAssertTrue(touched)
        let removed = await store.remove(id); XCTAssertTrue(removed)
        let gone = await store.get(id); XCTAssertNil(gone)
        let removedAgain = await store.remove(id); XCTAssertFalse(removedAgain)
    }

    func testSessionsAreOpaqueAndIsolated() async {
        let store = StreamableHTTPSessionStore()
        let first = await store.create(); let second = await store.create()
        XCTAssertNotEqual(first, second)
        let found = await store.get(first); XCTAssertNotNil(found)
        let unknown = await store.get("not-a-session"); XCTAssertNil(unknown)
    }

    func testCleanupRemovesExpiredSessions() async {
        let store = StreamableHTTPSessionStore(ttl: 0)
        _ = await store.create()
        let removed = await store.removeExpired(now: Date().addingTimeInterval(1))
        XCTAssertEqual(removed, 1)
        let count = await store.count; XCTAssertEqual(count, 0)
    }
}
