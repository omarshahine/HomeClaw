import XCTest
@testable import HomeClaw

final class StreamableHTTPSessionStoreTests: XCTestCase {
    func testCreateGetTouchAndRemoveLifecycle() async throws {
        let store = StreamableHTTPSessionStore(ttl: 60)
        let raw = await store.create()
        let id = try XCTUnwrap(raw)
        XCTAssertFalse(id.isEmpty)
        let found = await store.get(id); XCTAssertNotNil(found)
        let touched = await store.touch(id); XCTAssertTrue(touched)
        let removed = await store.remove(id); XCTAssertTrue(removed)
        let gone = await store.get(id); XCTAssertNil(gone)
        let removedAgain = await store.remove(id); XCTAssertFalse(removedAgain)
    }

    func testSessionsAreOpaqueAndIsolated() async throws {
        let store = StreamableHTTPSessionStore()
        let r1 = await store.create(); let first = try XCTUnwrap(r1)
        let r2 = await store.create(); let second = try XCTUnwrap(r2)
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

    func testCreateEnforcesCap() async {
        let store = StreamableHTTPSessionStore(ttl: 60, maxSessions: 1)
        let first = await store.create(); XCTAssertNotNil(first)
        let second = await store.create(); XCTAssertNil(second)
        let cnt = await store.count; XCTAssertEqual(cnt, 1)
    }
}
