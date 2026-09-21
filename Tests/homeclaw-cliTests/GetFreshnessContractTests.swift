import Foundation
import Testing
@testable import homeclaw_cli
@Suite("get accessory freshness payload")
struct GetFreshnessContractTests {
    private func payload(
        refreshed: Any = true,
        attempted: Any = 1,
        succeeded: Any = 1,
        read: [String: Any]? = [
            "succeeded": true,
            "observed_at": "2026-09-10T14:00:00.125Z",
        ]
    ) -> [String: Any] {
        var characteristic: [String: Any] = ["name": "contact_state", "value": "0"]
        if let read { characteristic["read"] = read }
        return [
            "refreshed": refreshed,
            "read_attempted": attempted,
            "read_succeeded": succeeded,
            "services": [["characteristics": [characteristic]]],
        ]
    }
    @Test("A decoded socket envelope with consistent freshness is accepted")
    func acceptsDecodedFreshPayload() throws {
        let json = #"{"success":true,"data":{"refreshed":true,"read_attempted":1,"read_succeeded":1,"services":[{"characteristics":[{"read":{"succeeded":true,"observed_at":"2026-09-10T14:00:00.125Z"}}]}]}}"#
        let response = try JSONDecoder().decode(SocketClient.CLIResponse.self, from: Data(json.utf8))
        let detail = try #require(response.data?.value as? [String: Any])
        #expect(Get.refreshContractError(noRefresh: false, detail: detail) == nil)
    }
    @Test("Unattested or inconsistent freshness fails closed")
    func rejectsUnattestedPayloads() {
        let invalid = [
            payload(refreshed: false), payload(refreshed: "true"),
            payload(attempted: 2), payload(read: nil),
            payload(read: ["succeeded": true, "observed_at": "not-a-date"]),
            [:],
        ]
        for payload in invalid {
            #expect(Get.refreshContractError(noRefresh: false, detail: payload) != nil)
        }
    }

    @Test("Only explicit no-refresh accepts stale data")
    func explicitNoRefresh() {
        let stale: [String: Any] = [
            "refreshed": false, "read_attempted": 0,
            "read_succeeded": 0, "services": [],
        ]
        #expect(Get.refreshContractError(noRefresh: true, detail: stale) == nil)
        #expect(Get.refreshContractError(noRefresh: false, detail: stale) != nil)
    }

    @Test("A failed refresh names the cause and the --no-refresh escape hatch")
    func failureExplainsCause() throws {
        var offline = payload(refreshed: false, succeeded: 0)
        offline["reachable"] = false
        let offlineError = try #require(Get.refreshContractError(noRefresh: false, detail: offline))
        #expect(offlineError.contains("not reachable"))
        #expect(offlineError.contains("--no-refresh"))

        var partial = payload(refreshed: false, attempted: 2, succeeded: 1)
        partial["reachable"] = true
        let partialError = try #require(Get.refreshContractError(noRefresh: false, detail: partial))
        #expect(partialError.contains("1 of 2"))
    }
}
