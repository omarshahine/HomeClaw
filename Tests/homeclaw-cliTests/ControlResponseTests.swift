import Foundation
import Testing
@testable import homeclaw_cli

struct ControlResponseTests {
    @Test("Write outcome codes are additive to unsuccessful socket responses")
    func failureCode() throws {
        let decoder = JSONDecoder()
        let response = try decoder.decode(
            SocketClient.CLIResponse.self,
            from: Data(#"{"success":false,"error":"Write unconfirmed","error_code":"write_unconfirmed"}"#.utf8)
        )
        #expect(!response.success)
        #expect(response.error == "Write unconfirmed")
        #expect(response.errorCode == "write_unconfirmed")
        let legacy = try decoder.decode(
            SocketClient.CLIResponse.self,
            from: Data(#"{"success":false,"error":"Old response"}"#.utf8)
        )
        #expect(!legacy.success)
        #expect(legacy.errorCode == nil)
    }
}
