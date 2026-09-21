import XCTest
@testable import HomeClaw

final class StreamableHTTPSessionStoreTests: XCTestCase {
    func testCreateGetTouchAndRemoveLifecycle() async throws {
        let store = StreamableHTTPSessionStore(ttl: 60)
        let raw = await store.create()
        let id = try XCTUnwrap(raw?.id)
        XCTAssertFalse(id.isEmpty)
        let found = await store.get(id); XCTAssertNotNil(found)
        let touched = await store.touch(id); XCTAssertTrue(touched)
        let removed = await store.remove(id); XCTAssertTrue(removed)
        let gone = await store.get(id); XCTAssertNil(gone)
        let removedAgain = await store.remove(id); XCTAssertFalse(removedAgain)
    }

    func testSessionsAreOpaqueAndIsolated() async throws {
        let store = StreamableHTTPSessionStore()
        let r1 = await store.create(); let first = try XCTUnwrap(r1?.id)
        let r2 = await store.create(); let second = try XCTUnwrap(r2?.id)
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

    func testFullStoreEvictsLeastRecentlyUsedSession() async throws {
        let store = StreamableHTTPSessionStore(ttl: 3600, maxSessions: 2)
        let t0 = Date()
        let ra = await store.create(now: t0); let a = try XCTUnwrap(ra).id
        let rb = await store.create(now: t0.addingTimeInterval(1)); let b = try XCTUnwrap(rb).id
        // Touch `a` so `b` becomes the least recently used.
        let touched = await store.validateAndTouch(a, now: t0.addingTimeInterval(2)); XCTAssertNotNil(touched)
        let rc = await store.create(now: t0.addingTimeInterval(3)); let c = try XCTUnwrap(rc)
        XCTAssertEqual(c.evicted, b)
        let count = await store.count; XCTAssertEqual(count, 2)
        let ga = await store.get(a), gb = await store.get(b), gc = await store.get(c.id)
        XCTAssertNotNil(ga); XCTAssertNil(gb); XCTAssertNotNil(gc)
    }

    func testEvictionSparesProtectedSessionsWhenPossible() async throws {
        let store = StreamableHTTPSessionStore(ttl: 3600, maxSessions: 2)
        let t0 = Date()
        let rs = await store.create(now: t0); let streaming = try XCTUnwrap(rs).id
        let ri = await store.create(now: t0.addingTimeInterval(1)); let idle = try XCTUnwrap(ri).id
        // `streaming` is older, but it has a live SSE stream.
        let rc = await store.create(protected: [streaming], now: t0.addingTimeInterval(2)); let created = try XCTUnwrap(rc)
        XCTAssertEqual(created.evicted, idle)
        // When every session is protected, the oldest is evicted anyway.
        let rn = await store.create(protected: [streaming, created.id], now: t0.addingTimeInterval(3)); let next = try XCTUnwrap(rn)
        XCTAssertEqual(next.evicted, streaming)
    }

    func testFullStoreDropsExpiredSessionsBeforeEvicting() async throws {
        let store = StreamableHTTPSessionStore(ttl: 10, maxSessions: 1)
        let t0 = Date()
        _ = await store.create(now: t0)
        let rc = await store.create(now: t0.addingTimeInterval(11)); let created = try XCTUnwrap(rc)
        XCTAssertNil(created.evicted, "An expired session is cleanup, not an eviction")
        let count = await store.count; XCTAssertEqual(count, 1)
    }

    func testCreateRecordsNegotiatedProtocolVersion() async throws {
        let store = StreamableHTTPSessionStore()
        let rc = await store.create(protocolVersion: "2025-06-18"); let id = try XCTUnwrap(rc).id
        let session = await store.get(id)
        XCTAssertEqual(session?.protocolVersion, "2025-06-18")
    }
}
