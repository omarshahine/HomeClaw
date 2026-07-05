import Foundation
import Testing
@testable import homeclaw_cli

// Tests for the uniform input-handling work from issue #76: the shared
// file-or-stdin reader, the assign-rooms JSON parser (bare array + wrapper),
// and the shared scene-reference formatter used by `automations list`/`get`.

// MARK: - readCommandInputData (file path or '-' stdin)

@Suite("readCommandInputData")
struct ReadCommandInputDataTests {
    @Test("reads an existing file")
    func readsFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("homeclaw-input-test-\(UUID().uuidString).json")
        let payload = Data("{\"assignments\": []}".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try readCommandInputData(url.path)
        #expect(data == payload)
    }

    @Test("missing file throws a ValidationError that mentions the stdin escape hatch")
    func missingFileError() {
        do {
            _ = try readCommandInputData("/nonexistent/path/definitely-missing.json")
            Issue.record("expected readCommandInputData to throw")
        } catch {
            let message = "\(error)"
            #expect(message.contains("stdin"))
            #expect(message.contains("'-'"))
        }
    }
}

// MARK: - AssignRooms.parseAssignments (bare array or wrapper object)

@Suite("AssignRooms.parseAssignments")
struct ParseAssignmentsTests {
    @Test("bare array of accessory/room objects")
    func bareArray() throws {
        let json = Data("""
        [{"accessory": "Desk Lamp", "room": "Office"}, {"uuid": "ABC-123", "room": "Kitchen"}]
        """.utf8)
        let result = try AssignRooms.parseAssignments(json)
        #expect(result.count == 2)
        #expect(result[0]["accessory"] == "Desk Lamp")
        #expect(result[1]["uuid"] == "ABC-123")
    }

    @Test("wrapper object with assignments key")
    func wrapperObject() throws {
        let json = Data("""
        {"assignments": [{"accessory": "Desk Lamp", "room": "Office"}]}
        """.utf8)
        let result = try AssignRooms.parseAssignments(json)
        #expect(result.count == 1)
        #expect(result[0]["room"] == "Office")
    }

    @Test("empty bare array is valid")
    func emptyArray() throws {
        let result = try AssignRooms.parseAssignments(Data("[]".utf8))
        #expect(result.isEmpty)
    }

    @Test("wrapper without assignments key is rejected")
    func wrapperMissingKey() {
        #expect(throws: (any Error).self) {
            _ = try AssignRooms.parseAssignments(Data("{\"rows\": []}".utf8))
        }
    }

    @Test("array of non-string values is rejected")
    func nonStringValues() {
        #expect(throws: (any Error).self) {
            _ = try AssignRooms.parseAssignments(Data("[{\"accessory\": 42, \"room\": \"Office\"}]".utf8))
        }
    }

    @Test("malformed JSON is rejected")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try AssignRooms.parseAssignments(Data("not json".utf8))
        }
    }
}

// MARK: - formatSceneReferences (uniform list/get scene rendering)

@Suite("formatSceneReferences")
struct FormatSceneReferencesTests {
    @Test("renders names from structured action_sets")
    func structuredActionSets() {
        let auto: [String: Any] = [
            "action_sets": [
                ["id": "A", "name": "Main Blinds - Close", "action_count": 3],
                ["id": "B", "name": "Porch On", "action_count": 1],
            ]
        ]
        #expect(formatSceneReferences(auto) == "Main Blinds - Close, Porch On")
    }

    @Test("annotates hidden trigger-owned action sets")
    func hiddenAnnotation() {
        let auto: [String: Any] = [
            "action_sets": [
                ["id": "A", "name": "9EDAED55-98B1-54E2-B865-2BEF24949DD3", "action_count": 2, "hidden": true]
            ]
        ]
        #expect(formatSceneReferences(auto) == "9EDAED55-98B1-54E2-B865-2BEF24949DD3 (hidden)")
    }

    @Test("falls back to legacy scenes name array")
    func legacyFallback() {
        let auto: [String: Any] = ["scenes": ["Evening", "Night"]]
        #expect(formatSceneReferences(auto) == "Evening, Night")
    }

    @Test("empty when no scene data present")
    func emptyWhenAbsent() {
        #expect(formatSceneReferences([:]).isEmpty)
    }
}
